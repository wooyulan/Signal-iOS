//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation

public extension TSGroupMemberRole {
    static func role(for value: GroupsProtoMemberRole) -> TSGroupMemberRole? {
        switch value {
        case .`default`:
            return .normal
        case .administrator:
            return .administrator
        default:
            owsFailDebug("Invalid value: \(value.rawValue)")
            return nil
        }
    }

    var asProtoRole: GroupsProtoMemberRole {
        switch self {
        case .normal:
            return .`default`
        case .administrator:
            return .administrator
        }
    }
}

// MARK: -

// This class is immutable.
@objc
public class GroupMembership: MTLModel {
    // This class is immutable.
    @objc(_TtCC16SignalServiceKit15GroupMembership11MemberState)
    class MemberState: MTLModel {
        @objc
        var role: TSGroupMemberRole = .normal

        @objc
        var isPending: Bool = false

        // Only applies for pending members.
        @objc
        var addedByUuid: UUID?

        @objc
        public override init() {
            super.init()
        }

        init(role: TSGroupMemberRole,
             isPending: Bool,
             addedByUuid: UUID? = nil) {
            self.role = role
            self.isPending = isPending
            self.addedByUuid = addedByUuid

            super.init()
        }

        @objc
        required public init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
        }

        @objc
        public required init(dictionary dictionaryValue: [String: Any]!) throws {
            try super.init(dictionary: dictionaryValue)
        }

        @objc
        public var isAdministrator: Bool {
            return role == .administrator
        }
    }

    // This class is immutable.
    @objc(GroupMembershipInvalidInviteModel)
    class InvalidInviteModel: MTLModel {
        @objc
        var userId: Data?

        @objc
        var addedByUserId: Data?

        @objc
        public override init() {
            super.init()
        }

        init(userId: Data?, addedByUserId: Data? = nil) {
            self.userId = userId
            self.addedByUserId = addedByUserId

            super.init()
        }

        @objc
        required public init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
        }

        @objc
        public required init(dictionary dictionaryValue: [String: Any]!) throws {
            try super.init(dictionary: dictionaryValue)
        }
    }

    // By using a single dictionary we ensure that no address has more than one state.
    typealias MemberStateMap = [SignalServiceAddress: MemberState]
    @objc
    var memberStateMap: MemberStateMap

    typealias InvalidInviteMap = [Data: InvalidInviteModel]
    @objc
    var invalidInviteMap: InvalidInviteMap

    @objc
    public var nonAdminMembers: Set<SignalServiceAddress> {
        return Set(memberStateMap.filter { !$0.value.isAdministrator && !$0.value.isPending }.keys)
    }
    @objc
    public var nonPendingAdministrators: Set<SignalServiceAddress> {
        return Set(memberStateMap.filter { $0.value.isAdministrator && !$0.value.isPending }.keys)
    }
    @objc
    public var nonPendingMembers: Set<SignalServiceAddress> {
        return Set(memberStateMap.filter { !$0.value.isPending }.keys)
    }

    @objc
    public var pendingNonAdminMembers: Set<SignalServiceAddress> {
        return Set(memberStateMap.filter { !$0.value.isAdministrator && $0.value.isPending }.keys)
    }
    @objc
    public var pendingAdministrators: Set<SignalServiceAddress> {
        return Set(memberStateMap.filter { $0.value.isAdministrator && $0.value.isPending }.keys)
    }
    // pendingMembers includes normal and administrator "pending members".
    @objc
    public var pendingMembers: Set<SignalServiceAddress> {
        return Set(memberStateMap.filter { $0.value.isPending }.keys)
    }

    @objc
    public var pendingAndNonPendingMemberCount: Int {
        return memberStateMap.count
    }

    // allUsers includes _all_ users:
    //
    // * Normal and administrator.
    // * Pending and non-pending.
    @objc
    public var allUsers: Set<SignalServiceAddress> {
        return Set(memberStateMap.keys)
    }

    public struct Builder {
        private var memberStateMap = MemberStateMap()
        private var invalidInviteMap = InvalidInviteMap()

        public init() {}

        internal init(memberStateMap: MemberStateMap, invalidInviteMap: InvalidInviteMap) {
            self.memberStateMap = memberStateMap
            self.invalidInviteMap = invalidInviteMap
        }

        public mutating func remove(_ uuid: UUID) {
            remove(SignalServiceAddress(uuid: uuid))
        }

        public mutating func remove(_ address: SignalServiceAddress) {
            memberStateMap.removeValue(forKey: address)
        }

        public mutating func remove(_ addresses: Set<SignalServiceAddress>) {
            for address in addresses {
                remove(address)
            }
        }

        public mutating func addNonPendingMember(_ uuid: UUID,
                                                 role: TSGroupMemberRole) {
            addNonPendingMember(SignalServiceAddress(uuid: uuid), role: role)
        }

        public mutating func addNonPendingMember(_ address: SignalServiceAddress,
                                                 role: TSGroupMemberRole) {
            addNonPendingMembers([address], role: role)
        }

        public mutating func addNonPendingMembers(_ addresses: Set<SignalServiceAddress>,
                                                  role: TSGroupMemberRole) {
            for address in addresses {
                if memberStateMap[address] != nil {
                    owsFailDebug("Duplicate address.")
                }
                memberStateMap[address] = MemberState(role: role, isPending: false, addedByUuid: nil)
            }
        }

        public mutating func addPendingMember(_ uuid: UUID,
                                              role: TSGroupMemberRole,
                                              addedByUuid: UUID) {
            addPendingMember(SignalServiceAddress(uuid: uuid), role: role, addedByUuid: addedByUuid)
        }

        public mutating func addPendingMember(_ address: SignalServiceAddress,
                                              role: TSGroupMemberRole,
                                              addedByUuid: UUID) {
            addPendingMembers([address], role: role, addedByUuid: addedByUuid)
        }

        public mutating func addPendingMembers(_ addresses: Set<SignalServiceAddress>,
                                               role: TSGroupMemberRole,
                                               addedByUuid: UUID) {
            for address in addresses {
                if memberStateMap[address] != nil {
                    Logger.error("Duplicate address.")
                    continue
//                    owsFailDebug("Duplicate address.")
                }
                memberStateMap[address] = MemberState(role: role, isPending: true, addedByUuid: addedByUuid)
            }
        }

        public mutating func copyMember(_ address: SignalServiceAddress,
                                        from oldGroupMembership: GroupMembership) {
            guard let memberState = oldGroupMembership.memberStateMap[address] else {
                owsFailDebug("Unknown address")
                return
            }
            if memberStateMap[address] != nil {
                owsFailDebug("Duplicate address.")
            }
            memberStateMap[address] = memberState
        }

        public mutating func addInvalidInvite(userId: Data, addedByUserId: Data) {
            invalidInviteMap[userId] = InvalidInviteModel(userId: userId, addedByUserId: addedByUserId)
        }

        public mutating func removeInvalidInvite(userId: Data) {
            invalidInviteMap.removeValue(forKey: userId)
        }

        public mutating func copyInvalidInvites(from other: GroupMembership) {
            assert(invalidInviteMap.isEmpty)
            invalidInviteMap = other.invalidInviteMap
        }

        internal func asMemberStateMap() -> MemberStateMap {
            return memberStateMap
        }

        public func build() -> GroupMembership {
            var memberStateMap = self.memberStateMap

            let localProfileInvariantAddress = SignalServiceAddress(phoneNumber: kLocalProfileInvariantPhoneNumber)
            if memberStateMap[localProfileInvariantAddress] != nil {
                owsFailDebug("Removing localProfileInvariantAddress.")
                memberStateMap.removeValue(forKey: localProfileInvariantAddress)
            }

            return GroupMembership(memberStateMap: memberStateMap,
                                   invalidInviteMap: invalidInviteMap)
        }
    }

    @objc
    public override init() {
        self.memberStateMap = MemberStateMap()
        self.invalidInviteMap = [:]

        super.init()
    }

    @objc
    required public init?(coder aDecoder: NSCoder) {
        self.memberStateMap = MemberStateMap()
        self.invalidInviteMap = [:]

        super.init(coder: aDecoder)
    }

    @objc
    public required init(dictionary dictionaryValue: [String: Any]!) throws {
        self.memberStateMap = MemberStateMap()
        self.invalidInviteMap = [:]

        try super.init(dictionary: dictionaryValue)
    }

    internal init(memberStateMap: MemberStateMap, invalidInviteMap: InvalidInviteMap) {
        self.memberStateMap = memberStateMap
        self.invalidInviteMap = invalidInviteMap

        super.init()
    }

    @objc
    public init(v1Members: Set<SignalServiceAddress>) {
        var builder = Builder()
        builder.addNonPendingMembers(v1Members, role: .normal)
        self.memberStateMap = builder.asMemberStateMap()
        self.invalidInviteMap = [:]

        super.init()
    }

    @objc
    public static var empty: GroupMembership {
        return Builder().build()
    }

    public func role(for uuid: UUID) -> TSGroupMemberRole? {
        return role(for: SignalServiceAddress(uuid: uuid))
    }

    public func role(for address: SignalServiceAddress) -> TSGroupMemberRole? {
        guard let memberState = memberStateMap[address] else {
            return nil
        }
        return memberState.role
    }

    public func isAdministrator(_ address: SignalServiceAddress) -> Bool {
        guard let memberState = memberStateMap[address] else {
            return false
        }
        return memberState.isAdministrator
    }

    public func isAdministrator(_ uuid: UUID) -> Bool {
        return isAdministrator(SignalServiceAddress(uuid: uuid))
    }

    @objc
    public func isNonPendingMember(_ address: SignalServiceAddress) -> Bool {
        guard let memberState = memberStateMap[address] else {
            return false
        }
        return !memberState.isPending
    }

    public func isNonPendingMember(_ uuid: UUID) -> Bool {
        return isNonPendingMember(SignalServiceAddress(uuid: uuid))
    }

    @objc
    public func isPendingMember(_ address: SignalServiceAddress) -> Bool {
        guard let memberState = memberStateMap[address] else {
            return false
        }
        return memberState.isPending
    }

    public func isPendingMember(_ uuid: UUID) -> Bool {
        isPendingMember(SignalServiceAddress(uuid: uuid))
    }

    // When we check "is X a member?" we might mean...
    //
    // * Is X a "full" member or a pending member?
    // * Is X a "full" member and not a pending member?
    // * Is X a "normal" member and not an administrator member?
    // * Is X a "normal" member or an administrator member?
    // * Some combination thereof.
    //
    // This method is intended tests the inclusive case: pending
    // or non-pending, any role.
    @objc
    public func isPendingOrNonPendingMember(_ address: SignalServiceAddress) -> Bool {
        return memberStateMap[address] != nil
    }

    public func isPendingOrNonPendingMember(_ uuid: UUID) -> Bool {
        return isPendingOrNonPendingMember(SignalServiceAddress(uuid: uuid))
    }

    public func addedByUuid(forPendingMember address: SignalServiceAddress) -> UUID? {
        assert(isPendingMember(address))

        return memberStateMap[address]?.addedByUuid
    }

    @objc
    public static func normalize(_ addresses: [SignalServiceAddress]) -> [SignalServiceAddress] {
        return Array(Set(addresses))
            .sorted(by: { (l, r) in l.compare(r) == .orderedAscending })
    }

    public func hasInvalidInvite(forUserId userId: Data) -> Bool {
        return invalidInviteMap[userId] != nil
    }

    public var invalidInvites: [InvalidInvite] {
        var result = [InvalidInvite]()
        for invalidInvite in invalidInviteMap.values {
            guard let userId = invalidInvite.userId else {
                owsFailDebug("Missing userId.")
                continue
            }
            guard let addedByUserId = invalidInvite.addedByUserId else {
                owsFailDebug("Missing addedByUserId.")
                continue
            }
            result.append(InvalidInvite(userId: userId, addedByUserId: addedByUserId))
        }
        return result
    }

    public var asBuilder: Builder {
        return Builder(memberStateMap: memberStateMap, invalidInviteMap: invalidInviteMap)
    }

    public override var debugDescription: String {
        var result = "["
        for address in GroupMembership.normalize(Array(allUsers)) {
            guard let memberState = memberStateMap[address] else {
                owsFailDebug("Missing memberState.")
                continue
            }
            result += "\(address), isPending: \(memberState.isPending), isAdministrator: \(memberState.isAdministrator)\n"
        }
        result += "]"
        return result
    }
}
