import SwiftUI

extension View {
    /// A tooltip when there is something to say, and none when there is not.
    ///
    /// For text that is genuinely optional — a helper action's note, a card field's detail, a row's
    /// third line. It replaces `.help(text ?? "")` and `.help(cond ? text : "")`, which the
    /// 19 October tooltip audit found at about fifteen sites: an empty tooltip says nothing, and the
    /// `cond ? … : ""` form had hidden a worse habit — most of those controls explained themselves
    /// only while they *couldn't* be used. A control that can be pressed gets a real tooltip in
    /// both states, not this. `Scripts/check-tooltips.sh` refuses the empty string.
    @ViewBuilder
    func help(ifAny text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}
