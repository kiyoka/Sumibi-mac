import Foundation

/// 右Commandキーを単独で押して離した(タップした)かの判定。
///
/// 右Commandは`Command + C`などのショートカットにも使われるため、押した瞬間ではなく、
/// 他のキーやクリックを挟まずに短い時間で離したときだけを変換の操作とみなす。
public enum CommandTap {
    /// これより長く押していたら、タップではなく押し続けたものとみなす。
    public static let maximumDuration: TimeInterval = 0.4

    /// - Parameters:
    ///   - duration: 押してから離すまでの時間。
    ///   - onlyCommand: 押したときに、Command以外の修飾キー(Shift・Option・Control)が押されていなかったか。
    ///   - otherInput: 押している間に、他のキーやマウスボタンが押されたか。
    public static func isTap(duration: TimeInterval, onlyCommand: Bool, otherInput: Bool) -> Bool {
        onlyCommand && !otherInput && duration >= 0 && duration <= maximumDuration
    }
}
