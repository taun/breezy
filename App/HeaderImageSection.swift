import BreezyKit
import SwiftUI
import UniformTypeIdentifiers

/// The Media tab's header image: the page banner and the bookshelf thumbnail of a node, made from a picture that is
/// dropped, pasted or copied from a web address. The picture is fitted to the site's boxes and saved with the node's commit;
/// an address is only where the picture comes from and is never stored.
struct HeaderImageSection: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    let slug: String
    let header: NodeHeader

    // This device's choices, restored on relaunch: whether to make a thumbnail, and an address typed but not imported
    // yet, as "slug|address" so only the node it was typed for shows it.
    @AppStorage("header.thumbnail") private var makeThumbnail = true
    @AppStorage("header.address") private var addressRaw = ""
    /// A picture on its way to any node (one at a time), and the one for this node, if any: the view stays when
    /// another node is opened.
    private var busy: Bool { model.headerImageImport != nil }
    private var importing: AppModel.HeaderImageImport? {
        model.headerImageImport.flatMap { $0.isFor(slug, in: workspace) ? $0 : nil }
    }

    private var address: String {
        get { Self.address(addressRaw, for: slug) }
        nonmutating set { addressRaw = Self.stored(newValue, for: slug) }
    }

    /// The node's unsent address from the stored "slug|address", or "" when it was typed for another node.
    nonisolated static func address(_ stored: String, for slug: String) -> String {
        stored.hasPrefix(slug + "|") ? String(stored.dropFirst(slug.count + 1)) : ""
    }

    nonisolated static func stored(_ address: String, for slug: String) -> String { address.isEmpty ? "" : "\(slug)|\(address)" }

    var body: some View {
        Section {
            if let image = header.image { row("Banner", path: image) }
            if let teaser = header.teaser { row("Thumbnail", path: teaser) }
            dropZone
            Toggle("Make a thumbnail for the bookshelf", isOn: $makeThumbnail)
            HStack {
                PasteButton(supportedContentTypes: [.image]) { providers in
                    model.pasteHeaderImage(providers, slug: slug, in: workspace, makeThumbnail: makeThumbnail)
                }
                    .labelStyle(.titleAndIcon)
                    .disabled(busy) // a picture on its way would replace the pasted one when it lands
                Spacer()
                if header.image != nil || header.teaser != nil {
                    Button("Remove", role: .destructive) { run { try workspace.removeHeaderImage(slug: slug) } }
                        .buttonStyle(.borderless)
                        .disabled(importing != nil) // the picture on its way would put it back
                }
            }
            HStack {
                TextField("Image address", text: Binding(get: { address }, set: { address = $0 }))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { Task { await importAddress() } }
                    .disabled(busy)
                if importing?.fromAddress == true {
                    progress
                } else {
                    Button("Import") { Task { await importAddress() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Header image")
        } footer: {
            Text("Drop or paste a picture, or type its address. It is copied into the site, sized for the banner and the thumbnail, and saved with your next commit. The address is not kept.")
        }
    }

    /// A picture in use with its path and a menu to choose another file already in the site.
    private func row(_ title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                AssetMenu(paths: workspace.assetPaths) { chosen in
                    run {
                        let image = title == "Banner" ? chosen : header.image
                        let teaser = title == "Banner" ? header.teaser : chosen
                        try workspace.update(slug) { try $0.setHeader(image: image, teaser: teaser) }
                    }
                }
            }
            PreviewImage(image: MarkdownImage(alt: title, src: path), workspace: workspace)
                .frame(maxHeight: title == "Banner" ? 120 : 90)
                // Dropping on the banner replaces it, like the drop zone. Not the thumbnail: a picture always makes
                // the banner, so a drop there would change the banner instead.
                .imageDropTarget(enabled: title == "Banner", busy: busy, perform: drop)
            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    /// Where a picture can be dropped (Mac, iPad and iPhone: from Finder, Files, Photos, a browser…). Shows progress
    /// while a dropped picture is read or downloaded.
    private var dropZone: some View {
        Group {
            if importing?.fromAddress == false {
                progress
            } else if busy && importing == nil {
                // One at a time, for any node: say so here, with a way out, rather than only on the node it is for.
                VStack(spacing: 4) {
                    Text("Another picture is still being added.")
                    progress
                }
                .padding(.vertical, 8)
            } else {
                Label("Drop a picture here", systemImage: "photo.badge.plus")
                    .opacity(busy ? 0.5 : 1) // this node's address is downloading
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
        .imageDropTarget(busy: busy, perform: drop)
        #if os(iOS)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 } // the box spans the row; so does the line below it
        #endif
    }

    /// Asks for the drop's items at once, while it is being performed. Refused while another picture is on its way.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        model.dropHeaderImage(providers, slug: slug, in: workspace, makeThumbnail: makeThumbnail) != nil
    }

    /// A picture on its way, which can be stopped (a photo still downloading from iCloud, a slow website).
    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if model.headerImageImport?.cancelled == true {
                Text("Stopping…")
            } else {
                Button("Cancel") { model.cancelHeaderImage() }.buttonStyle(.borderless)
            }
        }
    }

    private func run(_ change: () throws -> Void) {
        do { try change() } catch { model.errorMessage = error.localizedDescription }
    }

    private func importAddress() async {
        let typed = address, node = slug
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty,
              let work = model.importHeaderImage(slug: node, from: typed, makeThumbnail: makeThumbnail, in: workspace)
        else { return }
        // Cleared only if it is still this node's address: another node's may have been typed meanwhile.
        if await work.value, addressRaw == Self.stored(typed, for: node) {
            addressRaw = ""
        }
    }
}

private struct ImageDropTarget: ViewModifier {
    let enabled: Bool
    /// Another picture is on its way: no highlight, and a drop is refused with a message saying why.
    let busy: Bool
    let perform: ([NSItemProvider]) -> Bool
    @State private var targeted = false

    /// `enabled` is fixed for a view (the thumbnail is never a target), so the branch never flips; `busy` changes
    /// often and only turns the highlight off, keeping the view's identity (a picture would reload).
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { target(content) } else { content }
    }

    private func target(_ content: Content) -> some View {
        content
            .overlay {
                if targeted && !busy {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: DroppedImage.types, isTargeted: $targeted, perform: perform)
    }
}

extension View {
    /// Accepts a dropped picture (see `DroppedImage`) and outlines the view while one is held over it.
    func imageDropTarget(enabled: Bool = true, busy: Bool, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        modifier(ImageDropTarget(enabled: enabled, busy: busy, perform: perform))
    }
}
