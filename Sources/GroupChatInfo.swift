import SwiftUI

struct GroupChatInfo: View {
    @ObservedObject var model: ChatModel
    let room: String
    let title: String
    @State private var adding = false
    @State private var search = ""
    @State private var selected: Set<String> = []

    private var language: Language { model.interfaceLanguage }
    private var members: [GroupMember] { model.groupRosters[room] ?? [] }
    private var pending: [String]? { model.pendingGroupInvites[room] }
    private var busy: Bool { model.invitingToGroup.contains(room) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button(language.label("그룹 멤버 새로고침"), systemImage: "arrow.clockwise") {
                    Task { await model.loadGroupRoster(room, refresh: true) }
                }.labelStyle(.iconOnly).disabled(model.loadingRosters.contains(room))
            }
            if adding { invitePicker }
            else { memberList }
            if let status = model.groupInfoStatus[room] {
                Text(status.text(in: language)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pending != nil {
                Button(language.label("초대 결과 확인")) { Task { await model.inviteGroupMembers([], to: room) } }
                    .disabled(busy)
            }
        }.padding(16).frame(width: 350)
            .task(id: room) { await model.loadGroupRoster(room, refresh: true) }
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.label("그룹 멤버 %@명", String(members.count))).foregroundStyle(.secondary)
                if model.loadingRosters.contains(room) { ProgressView().controlSize(.small) }
                Spacer()
                Button(language.label("멤버 추가"), systemImage: "plus") {
                    adding = true
                    search = ""
                    selected = []
                    Task { await model.refreshDirectory() }
                }.disabled(busy || pending != nil || model.groupRosters[room] == nil)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(members) { member in
                        HStack {
                            avatar(model.avatarImages[member.id])
                            Text(member.name).lineLimit(1)
                        }.onAppear { model.showGroupMemberAvatar(member, in: room) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(254, max(46, CGFloat(members.count) * 37)))
        }
    }

    private var invitePicker: some View {
        let existing = Set(members.map(\.id))
        let contacts = model.contacts.filter { contact in
            !existing.contains(contact.id) && !["filehelper", "brandsessionholder", "weixin", "notification_messages"].contains(contact.id)
                && (search.isEmpty || contact.title(in: language).localizedCaseInsensitiveContains(search) || contact.id.localizedCaseInsensitiveContains(search))
        }
        return VStack(alignment: .leading, spacing: 8) {
            TextField(language.label("초대할 연락처 검색"), text: $search).disabled(busy)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(contacts) { contact in
                        Toggle(isOn: Binding(get: { selected.contains(contact.id) }, set: { value in
                            if value && selected.count < 40 { selected.insert(contact.id) }
                            else if !value { selected.remove(contact.id) }
                        })) { Text(contact.title(in: language)).lineLimit(1) }
                            .disabled(busy || pending != nil || (selected.count >= 40 && !selected.contains(contact.id)))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 190)
            HStack {
                Button(language.label("돌아가기")) { adding = false }.disabled(busy)
                Spacer()
                Button(language.label("%@명 초대", String(selected.count))) {
                    let recipients = selected
                    Task {
                        await model.inviteGroupMembers(recipients, to: room)
                        adding = false
                    }
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || busy || pending != nil)
            }
        }
    }

    @ViewBuilder
    private func avatar(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.square").foregroundStyle(.secondary).frame(width: 28, height: 28).accessibilityHidden(true)
        }
    }
}
