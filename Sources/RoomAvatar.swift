import AppKit
import SwiftUI

struct RoomAvatar: View {
    let room: Room
    let members: [String]
    let images: [String: NSImage]
    private let size: CGFloat = 40

    var body: some View {
        Group {
            switch room.id {
            case "filehelper":
                ZStack {
                    Color(red: 0.14, green: 0.62, blue: 0.26)
                    Image(systemName: "folder.fill").font(.system(size: 24)).foregroundStyle(.white)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.14, green: 0.62, blue: 0.26)).offset(y: 2)
                }
            case "brandsessionholder":
                ZStack {
                    Color(red: 0.02, green: 0.61, blue: 0.91)
                    Image(systemName: "diamond.fill").font(.system(size: 21)).foregroundStyle(.white)
                }
            default:
                if room.isGroup, !members.isEmpty { memberGrid }
                else { tile(images[room.id], size: size, group: room.isGroup) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var memberGrid: some View {
        let ids = Array(members.prefix(9))
        let columns = ids.count > 4 ? 3 : 2
        let rowCount = (ids.count + columns - 1) / columns
        let cellSize = (size - 4 - CGFloat(columns - 1) * 1.5) / CGFloat(columns)
        return VStack(spacing: 1.5) {
            ForEach(0..<rowCount, id: \.self) { row in
                let start = row * columns
                HStack(spacing: 1.5) {
                    ForEach(ids[start..<min(start + columns, ids.count)], id: \.self) { id in
                        tile(images[id], size: cellSize)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.12))
    }

    private func tile(_ image: NSImage?, size: CGFloat, group: Bool = false) -> some View {
        ZStack {
            Color.secondary.opacity(0.13)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: group ? "person.2.fill" : "person.fill")
                    .font(.system(size: size * 0.44)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}
