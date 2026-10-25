import BreezyKit
import SwiftUI

struct NodeEditorView: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    let slug: String
    @Environment(\.scenePhase) private var scenePhase
    // Restored on relaunch: preview mode, and which field of which node was being edited ("slug|field").
    @AppStorage("editor.preview") private var showPreview = false
    @AppStorage("editor.focus") private var focusRaw = ""
    @FocusState private var focus: Field?

    enum Field: String { case title, summary, body }

    private var node: NodeFile? { workspace.nodes[slug] }

    var body: some View {
        if let node {
            ScrollViewReader { proxy in
            Form {
                let issues = workspace.issues(for: slug)
                if !issues.isEmpty {
                    Section {
                        ForEach(issues, id: \.message) { issue in
                            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? .red : .orange)
                        }
                    }
                }
                Section("Basics") {
                    TextField("Title", text: bind(\.title) { try $0.setTitle($1) })
                        .focused($focus, equals: .title).id(Field.title)
                    TypeField(type: bind(\.type) { try $0.setType($1) }, known: workspace.types)
                    TextField("Summary", text: bind(\.summary) { try $0.setSummary($1) }, axis: .vertical)
                        .focused($focus, equals: .summary).id(Field.summary)
                    CommitTextField("Tags, comma separated", value: node.tags.joined(separator: ", ")) { text in
                        edit { try $0.setTags(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
                    }
                    Toggle("Draft (not published)", isOn: bind(\.draft) { try $0.setDraft($1) })
                }
                DateSection(date: node.date) { new in edit { try $0.setDate(new) } }
                LinkEditorView(workspace: workspace, slug: slug)
                Section("Media") {
                    ForEach(NodeFile.stringKeys, id: \.self) { key in
                        HStack {
                            TextField(key.capitalized, text: Binding(
                                get: { node.strings[key] ?? "" },
                                set: { v in edit { try $0.setString(key, v) } }))
                                .autocorrectionDisabled()
                            if key == "slides" || key == "archive" {
                                AssetMenu(paths: workspace.assetPaths) { path in edit { try $0.setString(key, path) } }
                            }
                        }
                    }
                }
                Section {
                    Picker("Body", selection: $showPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if showPreview {
                        MarkdownPreview(node: node)
                    } else {
                        BodyEditor(text: Binding(get: { node.body }, set: { v in edit { $0.setBody(v) } }), slug: slug)
                            .focused($focus, equals: .body)
                            .font(.body.monospaced())
                            .frame(minHeight: 280)
                            .id(Field.body)
                    }
                } header: {
                    Text("Body")
                }
            }
            .formStyle(.grouped)
            .onChange(of: focus) { _, f in
                // Leaving the app also clears focus; only record changes made while in use.
                if scenePhase == .active { focusRaw = f.map { "\(slug)|\($0.rawValue)" } ?? "" }
            }
            .task {
                // Put the cursor back where it was, and scroll to it.
                let parts = focusRaw.split(separator: "|")
                guard parts.count == 2, parts[0] == slug, let f = Field(rawValue: String(parts[1])) else { return }
                if f == .body && showPreview { return }
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo(f, anchor: .center)
                focus = f
            }
            }
            .navigationTitle(node.title)
            .toolbar {
                if workspace.isModified(slug) {
                    ToolbarItem { Button("Revert") { try? workspace.revert(slug) } }
                }
            }
        }
    }

    /// Two-way binding to a decoded field whose setter rewrites the front matter.
    private func bind<T>(_ get: KeyPath<NodeFile, T>, _ set: @escaping (inout NodeFile, T) throws -> Void) -> Binding<T> {
        Binding(
            get: { workspace.nodes[slug]![keyPath: get] },
            set: { v in edit { try set(&$0, v) } })
    }

    private func edit(_ change: (inout NodeFile) throws -> Void) {
        do { try workspace.update(slug, change) } catch { model.errorMessage = error.localizedDescription }
    }
}

/// Date with year or day precision; year precision is the site's bare-year style.
struct DateSection: View {
    let date: NodeDate?
    let set: (NodeDate?) -> Void

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var year: Int { Int(date?.iso.prefix(4) ?? "") ?? Calendar.current.component(.year, from: .now) }

    var body: some View {
        Section("Date") {
            Toggle("Dated", isOn: Binding(get: { date != nil }, set: { on in
                set(on ? NodeDate(iso: "\(Calendar.current.component(.year, from: .now))-01-01", precision: .year) : nil)
            }))
            if let date {
                Picker("Precision", selection: Binding(get: { date.precision }, set: { p in
                    set(date.changingPrecision(to: p, todayISO: Self.toISO(.now)))
                })) {
                    Text("Year").tag(DatePrecision.year)
                    Text("Day").tag(DatePrecision.day)
                }
                .pickerStyle(.segmented)
                if date.precision == .year {
                    TextField("Year", value: Binding(get: { year }, set: { y in
                        if (1000...9999).contains(y) { set(NodeDate(iso: String(format: "%04d-01-01", y), precision: .year)) }
                    }), format: .number.grouping(.never))
                } else {
                    DatePicker("Day", selection: Binding(get: { Self.toDate(date.iso) }, set: { d in
                        set(NodeDate(iso: Self.toISO(d), precision: .day))
                    }), displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                }
            }
        }
    }

    static func toDate(_ iso: String) -> Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return .now }
        return utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) ?? .now
    }

    static func toISO(_ d: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }
}

/// Picks one of the existing files under src/assets.
struct AssetMenu: View {
    let paths: [String]
    let pick: (String) -> Void

    private var groups: [(String, [String])] {
        Dictionary(grouping: paths) { $0.split(separator: "/").dropFirst().first.map(String.init) ?? "" }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        Menu {
            ForEach(groups, id: \.0) { folder, files in
                Menu(folder) { ForEach(files, id: \.self) { p in Button((p as NSString).lastPathComponent) { pick(p) } } }
            }
        } label: {
            Image(systemName: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Choose an existing asset")
    }
}
