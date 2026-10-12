/// Marks events this app posts itself (the later paste slice stamps Cmd+V with this in
/// `eventSourceUserData`). Both taps pass stamped events through untouched and never count them as input.
public enum SyntheticEvents {
    public static let stamp: Int64 = 0x4D54_5950_4531
}
