import AppKit
import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// Upstream `AvatarUploadControl`: click to pick an image, crop it, upload
/// it, and hand the file URL to the caller to persist.
struct SquadsAvatarUploadControl: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let value: String?
    let name: String
    var size: CGFloat = 64
    var kind: AvatarKind = .squad
    let onUploaded: (String) async throws -> Void
    var onClear: (() -> Void)? = nil
    @State private var picked: SquadsPickedImage?
    @State private var busy = false
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { Task { await pick() } } label: {
                ZStack {
                    AvatarView(name: name, url: value, kind: kind, size: size)
                    if hovering || busy {
                        Color.black.opacity(0.4)
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "camera.fill").font(.system(size: size * 0.28)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .onHover { hovering = $0 }
            .help(tr("common", "avatar_upload.change"))
            if let onClear, value != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.background))
                        .overlay(Circle().strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
                .help(tr("common", "avatar_upload.remove"))
                .offset(x: 4, y: -4)
            }
        }
        .frame(width: size, height: size)
        .sheet(item: $picked) { p in
            SquadsAvatarCropSheet(image: p.image, busy: busy) { data in
                await upload(data, sourceName: p.name)
            } onCancel: {
                picked = nil
            }
        }
    }

    private func pick() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { (c: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { c.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            toaster.error(tr("common", "avatar_upload.select_image"))
            return
        }
        picked = SquadsPickedImage(image: image, name: url.deletingPathExtension().lastPathComponent)
    }

    private func upload(_ data: Data, sourceName: String) async {
        busy = true
        defer { busy = false }
        let attachment: Attachment
        do {
            attachment = try await session.api.uploadFile(name: "\(sourceName.isEmpty ? "avatar" : sourceName).jpg", mimeType: "image/jpeg", data: data)
        } catch {
            let m = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(m.isEmpty ? tr("common", "avatar_upload.failed") : m)
            return
        }
        do {
            try await onUploaded(attachment.url)
        } catch {
            return
        }
        picked = nil
        toaster.success(tr("common", "avatar_upload.updated"))
    }
}

struct SquadsPickedImage: Identifiable {
    let id = UUID()
    let image: CGImage
    let name: String
}

/// Upstream `AvatarCropDialog`: pan / zoom / rotate under a round window;
/// the output is a square 512 px JPEG (the circle is display-only).
struct SquadsAvatarCropSheet: View {
    let image: CGImage
    let busy: Bool
    let onSave: (Data) async -> Void
    let onCancel: () -> Void
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragStart: CGSize?
    @State private var turns = 0
    @State private var failed = false
    private let viewport: Double = 320

    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    private var rotated: CGSize { CGSize(SquadsAvatarCrop.rotatedSize(imageSize.squadsCrop, quarterTurns: turns)) }

    var body: some View {
        let s = SquadsAvatarCrop.scale(image: rotated.squadsCrop, viewport: viewport, zoom: zoom)
        let shown = CGSize(SquadsAvatarCrop.clampOffset(offset.squadsCrop, image: rotated.squadsCrop, viewport: viewport, zoom: zoom))
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("common", "avatar_crop.title")).font(Theme.Font.title)
            ZStack {
                Color(white: 0.1)
                if failed {
                    Text(tr("common", "avatar_crop.load_failed")).foregroundStyle(.white.opacity(0.7))
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: imageSize.width * s, height: imageSize.height * s)
                        .rotationEffect(.degrees(Double(turns) * 90))
                        .offset(shown)
                }
                SquadsCropMask().fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1).allowsHitTesting(false)
            }
            .frame(width: viewport, height: viewport)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let base = dragStart ?? shown
                        if dragStart == nil { dragStart = shown }
                        offset = CGSize(SquadsAvatarCrop.clampOffset(SquadsCropSize(width: base.width + v.translation.width, height: base.height + v.translation.height),
                                                                     image: rotated.squadsCrop, viewport: viewport, zoom: zoom))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .overlay(alignment: .topTrailing) {
                Button { turns = (turns + 1) % 4; offset = .zero } label: {
                    Image(systemName: "rotate.right").frame(width: 28, height: 28).background(Circle().fill(.background.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .padding(8)
                .disabled(busy)
                .help(tr("common", "avatar_crop.rotate"))
            }
            HStack(spacing: 8) {
                Button { zoom = max(SquadsAvatarCrop.zoomRange.lowerBound, zoom - 0.1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .help(tr("common", "avatar_crop.zoom_out"))
                Slider(value: $zoom, in: SquadsAvatarCrop.zoomRange)
                    .help(tr("common", "avatar_crop.zoom"))
                Button { zoom = min(SquadsAvatarCrop.zoomRange.upperBound, zoom + 0.1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(tr("common", "avatar_crop.zoom_in"))
                Button(tr("common", "avatar_crop.reset")) { zoom = 1; offset = .zero; turns = 0 }
                    .buttonStyle(.borderless)
                    .font(Theme.Font.caption)
            }
            .disabled(busy)
            .frame(width: viewport)
            HStack {
                Spacer()
                Button(tr("common", "avatar_crop.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(busy ? tr("common", "avatar_crop.uploading") : tr("common", "avatar_crop.apply")) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || failed)
            }
            .frame(width: viewport)
        }
        .padding(20)
        .interactiveDismissDisabled(busy)
    }

    private func save() async {
        let crop = CGRect(SquadsAvatarCrop.cropRect(image: rotated.squadsCrop, viewport: viewport, zoom: zoom, offset: offset.squadsCrop))
        let source = image
        let quarter = turns
        let data = await Task.detached(priority: .userInitiated) { SquadsAvatarRenderer.render(source, quarterTurns: quarter, crop: crop) }.value
        guard let data else {
            failed = true
            return
        }
        await onSave(data)
    }
}

private struct SquadsCropMask: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addEllipse(in: rect)
        return p
    }
}

enum SquadsAvatarRenderer {
    /// Rotates, crops and encodes to a square JPEG on a white bed.
    static func render(_ image: CGImage, quarterTurns: Int, crop: CGRect) -> Data? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rotatedSize = CGSize(SquadsAvatarCrop.rotatedSize(SquadsCropSize(width: w, height: h), quarterTurns: quarterTurns))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let rctx = CGContext(data: nil, width: Int(rotatedSize.width), height: Int(rotatedSize.height), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        switch quarterTurns % 4 {
        case 1:
            rctx.translateBy(x: 0, y: rotatedSize.height)
            rctx.rotate(by: -.pi / 2)
        case 2:
            rctx.translateBy(x: rotatedSize.width, y: rotatedSize.height)
            rctx.rotate(by: .pi)
        case 3:
            rctx.translateBy(x: rotatedSize.width, y: 0)
            rctx.rotate(by: .pi / 2)
        default:
            break
        }
        rctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rotated = rctx.makeImage(), let cropped = rotated.cropping(to: crop.integral) else { return nil }
        let side = SquadsAvatarCrop.outputSize
        guard let out = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: side, height: side))
        out.interpolationQuality = .high
        out.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let final = out.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: final).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

/// Upstream `SquadProfileCard` (hover card body for squad actors).
struct SquadsProfileCard: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let squadID: String
    @State private var hovering = false

    var body: some View {
        let store = session.squads
        Group {
            if let squad = store.item(squadID) {
                card(squad)
            } else if !store.isLoaded {
                HStack(spacing: 12) {
                    Circle().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).frame(width: 112, height: 14)
                        RoundedRectangle(cornerRadius: 3).frame(width: 80, height: 10)
                    }
                }
                .foregroundStyle(Color.primary.opacity(0.06))
            } else {
                Text(tr("squads", "profile_card.unavailable")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 288, alignment: .leading)
        .onHover { hovering = $0 }
        .task { await store.loadIfNeeded() }
    }

    private func card(_ squad: Squad) -> some View {
        let archived = squad.archivedAt != nil
        let preview = squad.memberPreview ?? []
        let count = SquadsListQuery.memberCount(squad)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: squad.name, url: squad.avatarUrl, kind: .squad, size: 40)
                HStack(spacing: 6) {
                    Text(squad.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if archived {
                        Text(tr("squads", "profile_card.archived"))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    }
                }
                Spacer(minLength: 4)
                if !archived {
                    Button(tr("squads", "profile_card.detail_link")) { nav.push(.squad(squad.id), title: squad.name) }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.brand)
                        .opacity(hovering ? 1 : 0)
                }
            }
            if !squad.description.isEmpty {
                Text(squad.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if count > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    (Text(tr("squads", "profile_card.members_section")) + Text("  · \(count)").monospacedDigit())
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                    ForEach(preview.prefix(3), id: \.memberId) { m in
                        Button {
                            nav.push(m.memberType == "agent" ? .agent(m.memberId) : .member(m.memberId))
                        } label: {
                            HStack(spacing: 8) {
                                ActorAvatar(type: m.memberType, id: m.memberId, size: 18)
                                Text(session.actorInfo(type: m.memberType, id: m.memberId).name).fontWeight(.medium).lineLimit(1)
                                Spacer(minLength: 4)
                                if m.memberType == "agent" && m.memberId == squad.leaderId {
                                    SquadsLeaderChip(compact: true)
                                }
                                if m.memberType == "member", let role = session.directory.member(userID: m.memberId)?.role {
                                    Text(role).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 56, alignment: .trailing)
                                }
                            }
                            .font(Theme.Font.caption)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                    if count - min(3, preview.count) > 0 {
                        Text(tr("squads", "profile_card.more_members", ["count": count - min(3, preview.count)]))
                            .font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                }
            }
        }
    }
}

/// Amber "Leader" chip with a crown.
struct SquadsLeaderChip: View {
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            if !compact { Image(systemName: "crown.fill").font(.system(size: 9)) }
            Text(tr("squads", "members_tab.leader_chip")).lineLimit(1)
        }
        .font(.system(size: compact ? 10 : 11, weight: compact ? .medium : .regular))
        .foregroundStyle(Color(light: 0xB45309, dark: 0xFBBF24))
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(light: 0xFEF3C7, dark: 0x78350F).opacity(0.9)))
    }
}

private extension CGSize {
    var squadsCrop: SquadsCropSize { SquadsCropSize(width: width, height: height) }
    init(_ s: SquadsCropSize) { self.init(width: s.width, height: s.height) }
}

private extension CGRect {
    init(_ r: SquadsCropRect) { self.init(x: r.x, y: r.y, width: r.width, height: r.height) }
}
