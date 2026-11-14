public struct UsedType {}
public struct UnusedType {}
public func usedFunction() {}
public func unusedFunction() {}
public let unusedValue = "usedFunction appears only in a string"

// public func commentedOut() {}
let reference = UsedType()
_ = usedFunction

public protocol PublicContract {
    func protocolRequirement()
}
let protocolType: PublicContract.Type? = nil
