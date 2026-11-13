// Blink — a tiny menu bar reminder app that refuses to be ignored.
import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Look

enum Palette {
    static let coral = Color(red: 1, green: 0.45, blue: 0.35)
    static let pink = Color(red: 1, green: 0.3, blue: 0.55)
    static let violet = Color(red: 0.62, green: 0.42, blue: 1)
    static let amber = Color(red: 1, green: 0.74, blue: 0.28)
    static let teal = Color(red: 0.2, green: 0.8, blue: 0.72)
    static let sky = Color(red: 0.36, green: 0.66, blue: 1)
    static let all = [coral, pink, violet, amber, teal, sky]
}

let warm = LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 1, green: 0.3, blue: 0.52)],
                          startPoint: .topLeading, endPoint: .bottomTrailing)

extension Font {
    static func r(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

// MARK: - Model

enum Repeat: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly
    var id: String { rawValue }
    var label: String {
        switch self { case .none: "Once"; case .daily: "Every day"; case .weekdays: "Weekdays"; case .weekly: "Every week" }
    }

    func next(after d: Date, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        var n = d
        switch self {
        case .none: return nil
        case .daily: repeat { n = cal.date(byAdding: .day, value: 1, to: n)! } while n <= now
        case .weekly: repeat { n = cal.date(byAdding: .day, value: 7, to: n)! } while n <= now
        case .weekdays: repeat { n = cal.date(byAdding: .day, value: 1, to: n)! } while n <= now || cal.isDateInWeekend(n)
        }
        return n
    }
}

struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
    var rep: Repeat = .none
    var created = Date()

    init(text: String, date: Date, rep: Repeat = .none) { self.text = text; self.date = date; self.rep = rep }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        rep = try c.decodeIfPresent(Repeat.self, forKey: .rep) ?? .none
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    var emoji: String { Emoji.guess(text) }
    var tint: Color { Palette.all[Int(id.uuid.0) % Palette.all.count] }
}

enum Outcome: String, Codable {
    case done, snoozed, early, skipped
    var icon: String { switch self { case .done: "checkmark"; case .snoozed: "moon.zzz.fill"; case .early: "checkmark.circle"; case .skipped: "forward.fill" } }
    var color: Color { switch self { case .done, .early: Palette.teal; case .snoozed: Palette.violet; case .skipped: Palette.amber } }
    var label: String { switch self { case .done: "got it"; case .snoozed: "snoozed"; case .early: "done early"; case .skipped: "skipped" } }
}

struct Past: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var due: Date
    var at: Date
    var outcome: Outcome
    var note: String
}

enum Emoji {
    private static let map: [([String], String)] = [
        (["water", "drink", "hydrate"], "💧"), (["call", "phone", "ring", "facetime"], "📞"),
        (["meeting", "meet", "standup", "sync", "1:1", "interview"], "👥"),
        (["gym", "workout", "run", "exercise", "stretch", "walk", "yoga"], "💪"),
        (["eat", "lunch", "dinner", "breakfast", "food", "cook", "snack"], "🍜"),
        (["med", "meds", "pill", "pills", "vitamin", "vitamins"], "💊"), (["sleep", "bed", "nap"], "😴"),
        (["pay", "rent", "bill", "invoice", "bank", "tax", "taxes"], "💸"), (["mail", "email", "reply", "send", "text"], "✉️"),
        (["buy", "shop", "groceries", "order", "pick"], "🛒"), (["birthday", "gift", "party", "anniversary"], "🎁"),
        (["deploy", "push", "pr", "review", "ship", "release", "code", "merge"], "🚀"), (["read", "book"], "📖"),
        (["clean", "laundry", "dishes", "trash"], "🧺"), (["tea", "coffee"], "☕️"), (["break", "rest", "breathe", "relax"], "🌿"),
        (["doctor", "dentist", "appointment", "therapy"], "🩺"), (["plant", "plants", "garden"], "🪴"),
        (["mom", "dad", "mum", "family", "grandma", "grandpa"], "❤️"), (["write", "note", "journal", "blog"], "✍️"),
        (["study", "learn", "homework", "exam"], "🎓"), (["dog", "cat", "pet", "vet"], "🐾"), (["flight", "airport", "train", "pack"], "✈️"),
        (["focus", "deep", "work"], "🎯"),
    ]

    static func guess(_ text: String) -> String {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != ":" }).map(String.init))
        for (keys, e) in map where keys.contains(where: words.contains) { return e }
        return text.isEmpty ? "🔔" : "✨"
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var reminders: [Reminder] = []
    @Published var now = Date()
    @Published var undo: (reminder: Reminder, at: Date)?
    @Published var history: [Past] = []
    @Published var alert: AlertSound { didSet { UserDefaults.standard.set(alert.rawValue, forKey: "alertSound") } }
    var soundOn: Bool { alert != .off }
    var onFire: ((Reminder) -> Void)?

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Blink", isDirectory: true)
    }
    private let url: URL
    private let historyURL: URL

    private init() {
        alert = AlertSound(rawValue: UserDefaults.standard.string(forKey: "alertSound") ?? "")
            ?? (UserDefaults.standard.object(forKey: "soundOn") as? Bool == false ? .off : .chime)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("reminders.json")
        historyURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = saved
        }
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([Past].self, from: data) {
            history = saved
        }
        let t = Timer(timeInterval: 1, repeats: true) { _ in Task { @MainActor in Store.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
    }

    var upcoming: [Reminder] { reminders.sorted { $0.date < $1.date } }
    var next: Reminder? { upcoming.first }

    func add(_ text: String, at date: Date, rep: Repeat = .none) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        reminders.append(Reminder(text: clean.isEmpty ? "Hey, you!" : clean, date: date, rep: rep))
        save()
    }

    func remove(_ r: Reminder) {
        reminders.removeAll { $0.id == r.id }
        undo = (r, Date())
        save()
    }

    /// Done early: repeating reminders skip to their next occurrence.
    func complete(_ r: Reminder) {
        guard let i = reminders.firstIndex(where: { $0.id == r.id }) else { return }
        log(r, r.rep == .none ? .early : .skipped)
        if let n = r.rep.next(after: r.date) { reminders[i].date = n; reminders[i].created = Date(); save() } else {
            reminders.removeAll { $0.id == r.id }; save()
        }
    }

    func restoreUndo() {
        guard let u = undo else { return }
        reminders.append(u.reminder); undo = nil; save()
    }

    func tick() {
        now = Date()
        if let u = undo, now.timeIntervalSince(u.at) > 6 { undo = nil }
        var fired: [Reminder] = []
        for i in reminders.indices where reminders[i].date <= now {
            fired.append(reminders[i])
            if let n = reminders[i].rep.next(after: reminders[i].date, now: now) {
                reminders[i].date = n; reminders[i].created = now
            }
        }
        guard !fired.isEmpty else { return }
        reminders.removeAll { $0.date <= now }
        save()
        fired.sorted { $0.date < $1.date }.forEach { onFire?($0) }
    }

    func log(_ r: Reminder, _ o: Outcome, _ note: String = "") {
        history.insert(Past(text: r.text, due: r.date, at: Date(), outcome: o, note: note), at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        saveHistory()
    }

    func clearHistory() { history = []; saveHistory() }
    func again(_ p: Past) { add(p.text, at: Date().addingTimeInterval(15 * 60)) }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Sound

enum Sound: String { case chime, pop, done, engine }

enum AlertSound: String, CaseIterable, Identifiable {
    case chime, engine, custom, off
    var id: String { rawValue }
    var label: String {
        switch self { case .chime: "Chime"; case .engine: "Monster engine start"; case .custom: "Your own sound…"; case .off: "Silent" }
    }
}

@MainActor
enum Sounds {
    private static var live: [NSSound] = []

    static var customURL: URL? {
        (try? FileManager.default.contentsOfDirectory(at: Store.dir, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("custom-sound.") }
    }

    static func play(_ s: Sound) {
        guard Store.shared.soundOn else { return }
        if let url = Bundle.main.url(forResource: s.rawValue, withExtension: "wav") { start(url) } else { NSSound(named: "Glass")?.play() }
    }

    /// The reminder alert, using whatever sound is picked.
    static func alert() {
        switch Store.shared.alert {
        case .chime: play(.chime)
        case .engine: play(.engine)
        case .custom: if let u = customURL { start(u) } else { play(.chime) }
        case .off: break
        }
    }

    static func stopAll() { live.forEach { $0.stop() }; live.removeAll() }

    private static func start(_ url: URL) {
        guard let snd = NSSound(contentsOf: url, byReference: true) else { return }
        live.append(snd); if live.count > 6 { live.removeFirst() }
        snd.play()
    }

    static func chooseCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.title = "Pick your reminder sound"
        panel.prompt = "Use this sound"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        if let old = customURL { try? fm.removeItem(at: old) }
        let dst = Store.dir.appendingPathComponent("custom-sound." + (src.pathExtension.isEmpty ? "m4a" : src.pathExtension))
        do { try fm.copyItem(at: src, to: dst) } catch { return }
        Store.shared.alert = .custom
        stopAll(); alert()
    }
}

// MARK: - Natural-ish parsing ("call mom in 20m", "standup every weekday 9:30", "tea at 17:30")

struct Parsed { var text: String; var date: Date?; var rep: Repeat? }

enum TimeParser {
    private static let units = #"(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?)"#
    private static let relIn = try! NSRegularExpression(pattern: #"\bin\s+(\d+(?:\.\d+)?)\s*"# + units + #"\b"#, options: .caseInsensitive)
    private static let relEnd = try! NSRegularExpression(pattern: #"\s(\d+(?:\.\d+)?)\s*"# + units + #"\s*$"#, options: .caseInsensitive)
    private static let bareTime = try! NSRegularExpression(pattern: #"^\s*(?:at\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*$"#, options: .caseInsensitive)
    private static let timeWords = try! NSRegularExpression(pattern: #"\b(?:today|tonight|tomorrow|tmrw|at|on|next|this|(?:mon|tues|wednes|thurs|fri|satur|sun)day|\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?)\b"#, options: .caseInsensitive)
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let repRules: [(NSRegularExpression, Repeat, String)] = [
        (#"\bevery\s+weekdays?\b|\b(?:on\s+)?weekdays\b"#, Repeat.weekdays, " "),
        (#"\bevery\s*day\b|\bdaily\b"#, Repeat.daily, " "),
        (#"\bevery\s+week\b|\bweekly\b"#, Repeat.weekly, " "),
        (#"\bevery\s+((?:mon|tues|wednes|thurs|fri|satur|sun)day)\b"#, Repeat.weekly, " $1"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1, $0.2) }

    static func parse(_ input: String, now: Date = Date()) -> Parsed? {
        var s = input
        var rep: Repeat?
        for (re, r, tmpl) in repRules {
            let range = NSRange(s.startIndex..., in: s)
            if re.firstMatch(in: s, range: range) != nil {
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: tmpl); rep = r; break
            }
        }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        for re in [relIn, relEnd] {
            if let m = re.firstMatch(in: s, range: full), let n = Double(ns.substring(with: m.range(at: 1))) {
                let u = ns.substring(with: m.range(at: 2)).lowercased()
                let mult: Double = u.hasPrefix("s") ? 1 : u.hasPrefix("m") ? 60 : u.hasPrefix("h") ? 3600 : 86400
                return Parsed(text: strip(ns.replacingCharacters(in: m.range, with: " ")), date: now.addingTimeInterval(n * mult), rep: rep)
            }
        }
        if let m = detector.firstMatch(in: s, range: full), var d = m.date {
            // A bare "9:30" / "at 17" means that clock time (24h), not "the next 9:30 that happens to be pm".
            let lit = ns.substring(with: m.range)
            if let hm = bareTime.firstMatch(in: lit, range: NSRange(location: 0, length: (lit as NSString).length)) {
                let l = lit as NSString
                let h = Int(l.substring(with: hm.range(at: 1))) ?? 0
                let mi = hm.range(at: 2).location != NSNotFound ? Int(l.substring(with: hm.range(at: 2))) ?? 0 : 0
                if h < 24, mi < 60, let fixed = Calendar.current.date(bySettingHour: h, minute: mi, second: 0, of: now) { d = fixed }
            }
            if d < now && d > now.addingTimeInterval(-86400) { d = d.addingTimeInterval(86400) }
            if rep == .weekdays, Calendar.current.isDateInWeekend(d), let n = Repeat.weekdays.next(after: d, now: now) { d = n }
            if d > now {
                var t = strip(ns.replacingCharacters(in: m.range, with: " "))
                if t.isEmpty { // detector swallowed words like "dinner"/"lunch" — keep them, drop only the time bits
                    t = strip(timeWords.stringByReplacingMatches(in: s, range: full, withTemplate: " "))
                }
                return Parsed(text: t, date: d, rep: rep)
            }
        }
        return rep == nil ? nil : Parsed(text: strip(s), date: nil, rep: rep)
    }

    private static func strip(_ s: String) -> String {
        var words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        let junk: Set<String> = ["at", "on", "in", "by", "for", "-", "@", "every", "from"]
        while let last = words.last, junk.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }
}

// MARK: - Formatting

enum Fmt {
    static func countdown(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { let h = s / 3600, m = (s % 3600) / 60; return m == 0 ? "\(h)h" : "\(h)h \(m)m" }
        let d = s / 86400, h = (s % 86400) / 3600
        return h == 0 ? "\(d)d" : "\(d)d \(h)h"
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s < 3600 ? String(format: "%d:%02d", s / 60, s % 60) : countdown(t)
    }

    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func when(_ d: Date) -> String { "\(day(d)) \(time(d))" }
}

// MARK: - Small components

struct EmojiBadge: View {
    let emoji: String
    var tint: Color = Palette.coral
    var size: CGFloat = 32
    var body: some View {
        Text(emoji).font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.2)))
            .overlay(Circle().strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

struct Pill: View {
    let label: String
    var icon: String?
    var on = false
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            if !label.isEmpty { Text(label).lineLimit(1).fixedSize() }
        }
        .font(.r(11, .semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(on ? AnyShapeStyle(warm) : AnyShapeStyle(.primary.opacity(0.07))))
        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(Capsule())
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.r(10, .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.12)))
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI
    var radius: CGFloat = 0
    var dark = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active
        if dark { v.appearance = NSAppearance(named: .darkAqua) }
        if radius > 0 {
            v.maskImage = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { r in
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill(); return true
            }
            v.maskImage?.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            v.maskImage?.resizingMode = .stretch
        }
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Time scrubber: drag the timeline, the needle is "when"

struct TimeScrubber: View {
    @Binding var target: Date
    let now: Date
    var onTouch: () -> Void = {}
    @State private var base: Date?
    @State private var hovering = false
    private let px: CGFloat = 2.4 // points per minute

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Canvas { ctx, size in
                    let T = target.timeIntervalSinceReferenceDate
                    let half = Double(w / 2 / px) * 60
                    let nowX = w / 2 + CGFloat((now.timeIntervalSinceReferenceDate - T) / 60) * px
                    if nowX > 0 {
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: min(nowX, w), height: h)), with: .color(.primary.opacity(0.05)))
                        if nowX < w - 10 {
                            ctx.draw(Text("now").font(.r(8, .heavy)).foregroundColor(.secondary), at: CGPoint(x: nowX - 12, y: 9))
                        }
                    }
                    var t = floor((T - half) / 300) * 300
                    let cal = Calendar.current
                    while t <= T + half + 300 {
                        let x = w / 2 + CGFloat((t - T) / 60) * px
                        let d = Date(timeIntervalSinceReferenceDate: t)
                        let c = cal.dateComponents([.hour, .minute], from: d)
                        let m = c.minute ?? 0
                        let isHour = m == 0, isQuarter = m % 15 == 0
                        let th: CGFloat = isHour ? 16 : isQuarter ? 10 : 5
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: h - 6)); p.addLine(to: CGPoint(x: x, y: h - 6 - th))
                        let a = (d < now ? 0.15 : 1) * (isHour ? 0.6 : isQuarter ? 0.35 : 0.2)
                        ctx.stroke(p, with: .color(.primary.opacity(a)), style: StrokeStyle(lineWidth: isHour ? 1.6 : 1, lineCap: .round))
                        if isHour {
                            let label = c.hour == 0 ? Fmt.day(d).prefix(3).uppercased() : d.formatted(.dateTime.hour())
                            ctx.draw(Text(label).font(.r(9, .bold)).foregroundColor(.secondary), at: CGPoint(x: x, y: h - 6 - th - 8))
                        }
                        t += 300
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                             .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))

                Capsule().fill(warm).frame(width: 3, height: h - 4)
                    .shadow(color: Palette.pink.opacity(0.7), radius: base != nil ? 8 : 3)
                Triangle().fill(warm).frame(width: 10, height: 6).offset(y: -h / 2 + 3)
            }
        }
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(hovering ? 0.06 : 0.035)))
        .contentShape(Rectangle())
        .onHover { hovering = $0; $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if base == nil { base = target; onTouch() }
                var t = base!.timeIntervalSinceReferenceDate - Double(v.translation.width / px) * 60
                t = (t / 300).rounded() * 300
                let minT = ceil((now.timeIntervalSinceReferenceDate + 60) / 300) * 300
                let d = Date(timeIntervalSinceReferenceDate: max(t, minT))
                if d != target {
                    if Int(d.timeIntervalSinceReferenceDate) % 900 == 0 {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    target = d
                }
            }
            .onEnded { _ in base = nil })
        .help("Drag to pick a time")
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath() }
    }
}

// MARK: - Composer (shared by the menu popover and the ⌥⌘B quick-add panel)

struct QuickTime: Identifiable {
    let id: String
    let make: () -> Date
    static let all: [QuickTime] = [
        QuickTime(id: "15m") { Date().addingTimeInterval(15 * 60) },
        QuickTime(id: "1h") { Date().addingTimeInterval(3600) },
        QuickTime(id: "3h") { Date().addingTimeInterval(3 * 3600) },
        QuickTime(id: "Tonight") {
            let d = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
            return d > Date() ? d : d.addingTimeInterval(86400)
        },
        QuickTime(id: "Tomorrow") { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86400))! },
    ]
}

struct Composer: View {
    var big = false
    var allowCalendar = true
    var onAdded: () -> Void = {}

    @ObservedObject private var store = Store.shared
    @State private var text = ""
    @State private var target = Date().addingTimeInterval(15 * 60)
    @State private var rep: Repeat = .none
    @State private var chip: String? = "15m"
    @State private var showCal = false
    @State private var shake = 0
    @FocusState private var focused: Bool

    private var parsed: Parsed? { TimeParser.parse(text, now: store.now) }
    private var title: String { parsed?.text ?? text }

    var body: some View {
        VStack(alignment: .leading, spacing: big ? 16 : 12) {
            HStack(spacing: 10) {
                EmojiBadge(emoji: Emoji.guess(title), size: big ? 42 : 34)
                    .id(Emoji.guess(title))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Remind me to…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.r(big ? 24 : 18, .semibold))
                        .focused($focused)
                        .onSubmit(add)
                    Text(hint)
                        .font(.r(10, .medium)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .modifier(Shake(n: CGFloat(shake)))
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: Emoji.guess(title))

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(Fmt.time(target))
                    .font(.r(big ? 38 : 30, .bold)).monospacedDigit()
                    .foregroundStyle(warm)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: target)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.day(target)).font(.r(12, .semibold))
                    Text("in \(Fmt.countdown(target.timeIntervalSince(store.now)))").font(.r(11)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(Repeat.allCases) { r in
                        Button { rep = r } label: { r == rep ? Label(r.label, systemImage: "checkmark") : Label(r.label, systemImage: "") }
                    }
                } label: {
                    Pill(label: rep.label, icon: "repeat", on: rep != .none)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }

            TimeScrubber(target: $target, now: store.now) { chip = nil }

            HStack(spacing: 5) {
                ForEach(QuickTime.all) { q in
                    Button { withAnimation(.snappy) { chip = q.id; target = q.make() } } label: {
                        Pill(label: q.id, on: chip == q.id)
                    }.buttonStyle(.plain)
                }
                if allowCalendar {
                    Spacer(minLength: 0)
                    Button { showCal.toggle() } label: { Pill(label: "", icon: "calendar") }
                        .buttonStyle(.plain).help("Pick a date")
                        .popover(isPresented: $showCal, arrowEdge: .bottom) {
                            DatePicker("", selection: Binding(get: { target }, set: { target = $0; chip = nil }),
                                       in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.graphical).labelsHidden().padding(12)
                        }
                }
            }

            Button(action: add) {
                HStack {
                    Text(title.isEmpty ? "Remind me" : "Remind me \(Fmt.day(target).lowercased()) at \(Fmt.time(target))")
                        .lineLimit(1)
                    Spacer()
                    Keycap(text: "↩").foregroundStyle(.white).colorScheme(.dark)
                }
                .font(.r(13, .bold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(warm).opacity(title.isEmpty ? 0.45 : 1))
                .foregroundStyle(.white)
                .shadow(color: Palette.pink.opacity(title.isEmpty ? 0 : 0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .onChange(of: text) { _, _ in
            guard let p = parsed else { return }
            if let d = p.date { withAnimation(.snappy) { target = d }; chip = nil }
            if let r = p.rep { rep = r }
        }
        .onAppear {
            if let c = QuickTime.all.first(where: { $0.id == chip }) { target = c.make() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focused = true }
        }
    }

    private var hint: String {
        if text.isEmpty { return "try “stretch in 45m” or “standup every weekday 9:30”" }
        if let p = parsed {
            var bits: [String] = []
            if p.date != nil { bits.append("time") }
            if p.rep != nil { bits.append("repeat") }
            return "✦ picked up \(bits.joined(separator: " & ")) from your text"
        }
        return "drag the timeline, or type a time"
    }

    private func add() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            withAnimation(.default) { shake += 1 }; return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            store.add(title, at: target, rep: rep)
            text = ""; rep = .none; chip = "15m"; target = QuickTime.all[0].make()
        }
        Sounds.play(.pop)
        onAdded()
    }
}

struct Shake: GeometryEffect {
    var n: CGFloat
    var animatableData: CGFloat { get { n } set { n = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(n * .pi * 4), y: 0))
    }
}

// MARK: - Menu bar popover

struct PopoverView: View {
    enum Tab { case upcoming, history }
    @ObservedObject var store = Store.shared
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var tab: Tab = .upcoming
    @Namespace private var ns

    private var rest: [Reminder] { Array(store.upcoming.dropFirst()) }
    private var groups: [(String, [Reminder])] {
        var out: [(String, [Reminder])] = []
        for r in rest {
            let k = Fmt.day(r.date)
            if out.last?.0 == k { out[out.count - 1].1.append(r) } else { out.append((k, [r])) }
        }
        return out
    }
    private var historyGroups: [(String, [Past])] {
        var out: [(String, [Past])] = []
        for p in store.history {
            let cal = Calendar.current
            let k = cal.isDateInToday(p.at) ? "Today" : cal.isDateInYesterday(p.at) ? "Yesterday"
                : p.at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            if out.last?.0 == k { out[out.count - 1].1.append(p) } else { out.append((k, [p])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 14) {
            header

            if let n = store.next {
                HeroCard(r: n, now: store.now)
                    .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .opacity))
            }

            Composer()
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07)))

            HStack(spacing: 4) {
                tabButton(.upcoming, "Upcoming", count: store.reminders.count)
                tabButton(.history, "History", count: store.history.count)
                Spacer()
                if tab == .history && !store.history.isEmpty {
                    Button("Clear") { withAnimation { store.clearHistory() } }
                        .buttonStyle(.plain).font(.r(11, .medium)).foregroundStyle(.secondary)
                }
            }

            if tab == .upcoming { upcomingList.transition(.move(edge: .leading).combined(with: .opacity)) }
            else { historyList.transition(.move(edge: .trailing).combined(with: .opacity)) }

            if let u = store.undo {
                HStack {
                    Text("Removed “\(u.reminder.text)”").lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { withAnimation(.spring) { store.restoreUndo() } }
                        .buttonStyle(.plain).foregroundStyle(warm).fontWeight(.bold)
                }
                .font(.r(11, .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(.primary.opacity(0.06)))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            footer
        }
        .padding(16)
        .frame(width: 372)
        .background(alignment: .top) {
            RadialGradient(colors: [Palette.pink.opacity(0.22), Palette.coral.opacity(0.08), .clear],
                           center: .top, startRadius: 0, endRadius: 260)
                .frame(height: 260).allowsHitTesting(false)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.reminders)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.undo?.reminder.id)
    }

    private func tabButton(_ t: Tab, _ label: String, count: Int) -> some View {
        Button { withAnimation(.snappy) { tab = t } } label: {
            HStack(spacing: 5) {
                Text(label)
                if count > 0 {
                    Text("\(count)").font(.r(10, .bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Color.primary.opacity(0.08)))
                }
            }
            .font(.r(12, .semibold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background { if tab == t { Capsule().fill(warm).matchedGeometryEffect(id: "tab", in: ns) } }
            .foregroundStyle(tab == t ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).tracking(1.2)
            Text("\(count)").foregroundStyle(.quaternary)
        }
        .font(.r(9, .heavy)).foregroundStyle(.tertiary)
        .padding(.leading, 8).padding(.top, 2)
    }

    private func empty(_ emoji: String, _ text: String) -> some View {
        VStack(spacing: 4) {
            Text(emoji).font(.system(size: 26))
            Text(text).font(.r(12, .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    @ViewBuilder private var upcomingList: some View {
        if groups.isEmpty {
            empty("🌤", store.next == nil ? "Nothing to remember. Lucky you." : "Just the one up top. Easy day.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { g in
                        sectionHeader(g.0, g.1.count)
                        ForEach(g.1) { r in
                            Row(r: r, now: store.now)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                        removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 290)
            .fixedSize(horizontal: false, vertical: rest.count < 6)
        }
    }

    @ViewBuilder private var historyList: some View {
        if store.history.isEmpty {
            empty("🕰", "Nothing has gone off yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(historyGroups, id: \.0) { g in
                        sectionHeader(g.0, g.1.count)
                        ForEach(g.1) { PastRow(p: $0) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 290)
            .fixedSize(horizontal: false, vertical: store.history.count < 6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(warm).frame(width: 22, height: 22)
                Image(systemName: "bell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
            Text("blink").font(.r(17, .heavy))
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(store.now.formatted(date: .omitted, time: .shortened)).font(.r(13, .bold)).monospacedDigit()
                Text(store.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.r(10)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                Section("Alert sound") {
                    ForEach(AlertSound.allCases) { a in
                        Button {
                            Sounds.stopAll()
                            if a == .custom { Sounds.chooseCustom() } else { store.alert = a; Sounds.alert() }
                        } label: {
                            store.alert == a ? Label(a.label, systemImage: "checkmark") : Label(a.label, systemImage: "")
                        }
                    }
                }
                if store.alert != .off {
                    Divider()
                    Button("Preview") { Sounds.stopAll(); Sounds.alert() }
                    Button("Stop") { Sounds.stopAll() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.alert == .off ? "speaker.slash.fill" : store.alert == .engine ? "flame.fill" : "speaker.wave.2.fill")
                    Text(store.alert == .engine ? "vroom" : store.alert == .custom ? "custom" : store.alert == .off ? "silent" : "chime")
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Alert sound")

            Button { setLogin(!loginOn) } label: {
                Image(systemName: loginOn ? "sunrise.fill" : "sunrise")
            }
            .buttonStyle(.plain).help(loginOn ? "Opens at login" : "Open at login")

            Spacer()
            HStack(spacing: 3) { Keycap(text: "⌥⌘B"); Text("quick add") }.help("Press anywhere to add a reminder")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).help("Quit Blink")
        }
        .font(.r(11, .medium))
        .foregroundStyle(.secondary)
    }

    private func setLogin(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {}
        loginOn = SMAppService.mainApp.status == .enabled
    }
}

struct HeroCard: View {
    let r: Reminder
    let now: Date
    @State private var hover = false

    var body: some View {
        let left = r.date.timeIntervalSince(now)
        let total = max(1, r.date.timeIntervalSince(r.created))
        let prog = min(1, max(0.02, 1 - left / total))
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.primary.opacity(0.08), lineWidth: 4)
                Circle().trim(from: 0, to: prog)
                    .stroke(warm, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: prog)
                Text(r.emoji).font(.system(size: 24))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text("UP NEXT").font(.r(9, .heavy)).tracking(1.4).foregroundStyle(warm)
                Text(r.text).font(.r(15, .semibold)).lineLimit(2)
                HStack(spacing: 4) {
                    Text(Fmt.when(r.date))
                    if r.rep != .none { Image(systemName: "repeat"); Text(r.rep.label.lowercased()) }
                }
                .font(.r(11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 6) {
                    iconButton("checkmark", help: r.rep == .none ? "Done early" : "Skip this one") { Store.shared.complete(r) }
                    iconButton("xmark", help: "Delete") { Store.shared.remove(r) }
                }
                .transition(.opacity)
            } else {
                Text(Fmt.clock(left))
                    .font(.r(22, .bold)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Fmt.clock(left))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(warm.opacity(0.45), lineWidth: 1))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

@ViewBuilder
func iconButton(_ name: String, help: String, _ action: @escaping () -> Void) -> some View {
    Button { withAnimation(.spring) { action() } } label: {
        Image(systemName: name).font(.system(size: 11, weight: .bold))
            .frame(width: 26, height: 26)
            .background(Circle().fill(.primary.opacity(0.08)))
    }
    .buttonStyle(.plain).help(help)
}

struct Row: View {
    let r: Reminder
    let now: Date
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            EmojiBadge(emoji: r.emoji, tint: r.tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.text).font(.r(13, .medium)).lineLimit(1)
                HStack(spacing: 3) {
                    Text(Calendar.current.isDateInToday(r.date) || Calendar.current.isDateInTomorrow(r.date) ? Fmt.time(r.date) : Fmt.when(r.date))
                    if r.rep != .none { Image(systemName: "repeat") }
                }
                .font(.r(10)).foregroundStyle(.secondary)
            }
            Spacer()
            if hover {
                HStack(spacing: 4) {
                    iconButton("checkmark", help: r.rep == .none ? "Done early" : "Skip this one") { Store.shared.complete(r) }
                    iconButton("xmark", help: "Delete") { Store.shared.remove(r) }
                }
            } else {
                Text(Fmt.countdown(r.date.timeIntervalSince(now)))
                    .font(.r(11, .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear)))
        .onHover { hover = $0 }
    }
}

struct PastRow: View {
    let p: Past
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: p.outcome.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(p.outcome.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(p.outcome.color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.text).font(.r(13, .medium)).lineLimit(1).foregroundStyle(.secondary)
                Text("\(Fmt.time(p.due)) · \(p.outcome.label)\(p.note.isEmpty ? "" : " " + p.note)")
                    .font(.r(10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if hover {
                Button { withAnimation(.spring) { Store.shared.again(p) }; Sounds.play(.pop) } label: {
                    Label("again in 15m", systemImage: "arrow.uturn.forward")
                        .font(.r(10, .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Capsule().fill(.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            } else {
                Text(Emoji.guess(p.text)).font(.system(size: 13)).opacity(0.55)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear)))
        .onHover { hover = $0 }
    }
}

struct MenuLabel: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        if let n = store.next, n.date.timeIntervalSince(store.now) < 3600 {
            HStack(spacing: 3) {
                Image(systemName: "bell.badge.fill")
                Text(Fmt.countdown(n.date.timeIntervalSince(store.now))).monospacedDigit()
            }
        } else {
            Image(systemName: store.next == nil ? "bell" : "bell.fill")
        }
    }
}

// MARK: - Quick add panel (⌥⌘B from anywhere)

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct QuickAddView: View {
    let close: () -> Void
    @State private var saved = false

    var body: some View {
        ZStack {
            Composer(big: true, allowCalendar: false) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { saved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { close() }
            }
            .opacity(saved ? 0 : 1)
            .blur(radius: saved ? 8 : 0)

            if saved {
                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(warm).frame(width: 64, height: 64).shadow(color: Palette.pink.opacity(0.6), radius: 20)
                        Image(systemName: "checkmark").font(.system(size: 28, weight: .heavy)).foregroundStyle(.white)
                    }
                    Text("Noted. I'll blink.").font(.r(18, .bold))
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(VisualEffect(material: .hudWindow, radius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.12)))
        .background(alignment: .top) {
            RadialGradient(colors: [Palette.pink.opacity(0.25), .clear], center: .top, startRadius: 0, endRadius: 300)
                .clipShape(RoundedRectangle(cornerRadius: 26)).allowsHitTesting(false)
        }
        .onExitCommand(perform: close)
    }
}

@MainActor
final class QuickAdd {
    static let shared = QuickAdd()
    private var panel: KeyPanel?
    private var observer: Any?

    func toggle() { panel == nil ? open() : close() }

    func open() {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        let hc = NSHostingController(rootView: QuickAddView { QuickAdd.shared.close() })
        hc.sizingOptions = [.preferredContentSize]
        p.contentViewController = hc
        let size = hc.view.fittingSize
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.64 - size.height / 2,
                          width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { QuickAdd.shared.close() }
        }
        panel = p
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: {
            p.orderOut(nil)
        })
    }
}

private var hotKeyRef: EventHotKeyRef?

func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { QuickAdd.shared.toggle() } }
        return noErr
    }, 1, &spec, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x424C4E4B), id: 1) // 'BLNK'
    RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
}

// MARK: - The big, impossible-to-miss overlay

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var celebrateAt: Date?
    @Published var farewell: String?
}

struct Aurora: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.addFilter(.blur(radius: 110))
                let blobs: [(Color, Double, Double)] = [
                    (Palette.coral, 0.11, 0.34), (Palette.pink, 0.08, 0.30), (Palette.violet, 0.06, 0.38), (Palette.amber, 0.09, 0.22),
                ]
                for (i, b) in blobs.enumerated() {
                    let k = Double(i) * 1.7
                    let x = size.width * (0.5 + 0.32 * cos(t * b.1 + k))
                    let y = size.height * (0.5 + 0.28 * sin(t * b.1 * 1.4 + k * 2))
                    let r = min(size.width, size.height) * b.2
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(b.0.opacity(0.55)))
                }
            }
        }
    }
}

struct Bell: View {
    let emoji: String
    let start: Date
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            let ringPhase = t.truncatingRemainder(dividingBy: 3)
            let env = max(0, 1 - ringPhase / 0.9)
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    let p = (t / 2.8 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(warm, lineWidth: 3.5 * (1 - p) + 0.5)
                        .frame(width: 180, height: 180)
                        .scaleEffect(1 + p * 2.6)
                        .opacity((1 - p) * 0.75)
                }
                Circle().fill(warm).frame(width: 180, height: 180)
                    .shadow(color: Palette.pink.opacity(0.75), radius: 70)
                    .scaleEffect(1 + 0.035 * sin(t * 3.5))
                Text(emoji).font(.system(size: 96))
                    .rotationEffect(.degrees(sin(t * 30) * 18 * env), anchor: .top)
            }
        }
        .frame(width: 520, height: 400)
    }
}

struct SplitMix {
    var s: UInt64
    mutating func next() -> Double {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

struct Confetti: View {
    let start: Date
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSince(start)
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.4)
                var rng = SplitMix(s: 42)
                let colors = Palette.all + [.white]
                for i in 0..<220 {
                    let a = rng.next() * 2 * .pi
                    let speed = 400 + rng.next() * 1300
                    let spin = (rng.next() - 0.5) * 24
                    let w = 8 + rng.next() * 10, h = 5 + rng.next() * 6
                    let drag = 1 - min(0.6, t * 0.45)
                    let x = Double(origin.x) + cos(a) * speed * t * drag
                    let y = Double(origin.y) + sin(a) * speed * t * drag * 0.8 + 1100 * t * t
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(spin * t + Double(i)))
                    c.opacity = max(0, 1 - t / 1.3)
                    c.fill(Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 2),
                           with: .color(colors[i % colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct OverlayView: View {
    let reminder: Reminder
    let primary: Bool
    @ObservedObject var model: OverlayModel
    let onDone: () -> Void
    let onSnooze: (TimeInterval, String) -> Void
    @State private var start = Date()
    @State private var shown = false
    @State private var rumble = CGSize.zero

    private var leaving: Bool { model.celebrateAt != nil || model.farewell != nil }

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI, dark: true)
            Color(red: 0.06, green: 0.02, blue: 0.1).opacity(0.6)
            Aurora().opacity(0.9)

            VStack {
                HStack {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(warm).frame(width: 26, height: 26)
                            Image(systemName: "bell.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        }
                        Text("blink").font(.r(20, .heavy))
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(tl.date.formatted(date: .omitted, time: .standard)).font(.r(22, .bold)).monospacedDigit()
                            Text(tl.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.r(13)).opacity(0.6)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 48).padding(.top, 40)
                Spacer()
            }

            VStack(spacing: 22) {
                Bell(emoji: reminder.emoji, start: start)
                    .scaleEffect(shown ? 1 : 0.6)
                    .padding(.bottom, -40)

                Text(reminder.text)
                    .font(.r(84, .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.35)
                    .lineLimit(3)
                    .padding(.horizontal, 100)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 6)

                HStack(spacing: 10) {
                    Text(subtitle)
                    if reminder.rep != .none {
                        Text("·")
                        Image(systemName: "repeat")
                        Text("next \(Fmt.when(reminder.rep.next(after: reminder.date) ?? reminder.date))")
                    }
                }
                .font(.r(20, .medium)).foregroundStyle(.white.opacity(0.65))

                HStack(spacing: 12) {
                    snooze("5 min", 300, "1")
                    snooze("15 min", 900, "2")
                    snooze("1 hour", 3600, "3")
                    Button(action: onDone) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                            Text("Got it")
                        }
                        .font(.r(19, .bold))
                        .padding(.horizontal, 34).padding(.vertical, 16)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                        .shadow(color: .white.opacity(0.35), radius: 24)
                    }
                    .buttonStyle(Press())
                    .keyboardShortcut(primary ? .defaultAction : nil)
                }
                .padding(.top, 18)

                if primary {
                    HStack(spacing: 14) {
                        HStack(spacing: 5) { Keycap(text: "↩"); Text("got it") }
                        HStack(spacing: 5) { Keycap(text: "1"); Keycap(text: "2"); Keycap(text: "3"); Text("snooze") }
                        HStack(spacing: 5) { Keycap(text: "esc"); Text("5 min") }
                    }
                    .font(.r(12, .medium)).foregroundStyle(.white.opacity(0.4)).colorScheme(.dark)
                    .padding(.top, 6)
                    // hidden: Esc snoozes 5 minutes
                    Button("") { onSnooze(300, "5 min") }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
                }
            }
            .offset(rumble)
            .opacity(shown && !leaving ? 1 : 0)
            .scaleEffect(leaving ? 1.06 : shown ? 1 : 0.94)
            .blur(radius: leaving ? 12 : 0)

            if let f = model.farewell {
                Text(f).font(.r(56, .heavy)).foregroundStyle(.white)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if let c = model.celebrateAt {
                Text("Nice. ✨").font(.r(72, .heavy)).foregroundStyle(.white)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                Confetti(start: c)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: leaving)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.05)) { shown = true }
            if Store.shared.alert == .engine { shake() }
        }
    }

    /// The whole screen rumbles when the engine catches, and again on each throttle blip.
    private func shake() {
        for (at, len, power) in [(0.98, 0.9, 9.0), (2.7, 0.4, 5.0), (3.76, 0.5, 7.0)] {
            let frames = Int(len * 40)
            for i in 0...frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + at + Double(i) / 40) {
                    let k = power * (1 - Double(i) / Double(frames))
                    rumble = i == frames ? .zero : CGSize(width: .random(in: -k...k), height: .random(in: -k * 0.7...k * 0.7))
                }
            }
        }
    }

    private var subtitle: String {
        let late = Date().timeIntervalSince(reminder.date)
        return late > 90 ? "Was due \(Fmt.time(reminder.date)) · \(Fmt.countdown(late)) ago" : "It's \(Fmt.time(reminder.date))"
    }

    private func snooze(_ label: String, _ secs: TimeInterval, _ key: Character) -> some View {
        Button { onSnooze(secs, label) } label: {
            HStack(spacing: 7) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 13))
                Text(label)
            }
            .font(.r(16, .semibold))
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(Capsule().fill(.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
            .foregroundStyle(.white)
        }
        .buttonStyle(Press())
        .keyboardShortcut(primary ? KeyboardShortcut(KeyEquivalent(key), modifiers: []) : nil)
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

@MainActor
final class Overlay {
    static let shared = Overlay()
    private var queue: [Reminder] = []
    private var windows: [NSWindow] = []
    private var model = OverlayModel()
    private var soundTimer: Timer?
    private var leaving = false
    private var current: Reminder?

    func show(_ r: Reminder) {
        queue.append(r)
        if windows.isEmpty { presentNext() }
    }

    private func presentNext() {
        guard !queue.isEmpty else { return }
        let r = queue.removeFirst()
        current = r
        model = OverlayModel()
        leaving = false
        QuickAdd.shared.close()
        let main = NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let primary = screen == main
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OverlayView(
                reminder: r, primary: primary, model: model,
                onDone: { Overlay.shared.done() },
                onSnooze: { secs, label in Overlay.shared.snooze(r, secs, label) }))
            w.alphaValue = 0
            if primary { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.45; w.animator().alphaValue = 1 }
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        Sounds.alert()
        soundTimer = Timer.scheduledTimer(withTimeInterval: Store.shared.alert == .engine ? 20 : 15, repeats: true) { _ in
            Task { @MainActor in Sounds.alert() }
        }
    }

    func done() {
        guard !leaving else { return }
        leaving = true
        soundTimer?.invalidate()
        Sounds.stopAll()
        if let r = current { Store.shared.log(r, .done) }
        Sounds.play(.done)
        withAnimation { model.celebrateAt = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Overlay.shared.close() }
    }

    func snooze(_ r: Reminder, _ secs: TimeInterval, _ label: String) {
        guard !leaving else { return }
        leaving = true
        soundTimer?.invalidate()
        Sounds.stopAll()
        Store.shared.log(r, .snoozed, label)
        Store.shared.add(r.text, at: Date().addingTimeInterval(secs))
        Sounds.play(.pop)
        withAnimation { model.farewell = "See you in \(label) 👋" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { Overlay.shared.close() }
    }

    private func close() {
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            Task { @MainActor in
                closing.forEach { $0.orderOut(nil) }
                if !Overlay.shared.queue.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    Overlay.shared.presentNext()
                }
            }
        })
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Store.shared.onFire = { Overlay.shared.show($0) }
            Store.shared.tick() // fire anything missed while the app was closed
            registerHotKey()
        }
    }
}

@main
struct BlinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            MenuLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
