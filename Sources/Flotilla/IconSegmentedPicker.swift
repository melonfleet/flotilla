import SwiftUI

/// A segmented picker whose segments are pictures, each with its own tooltip.
///
/// **Never put `.help` on this or on any view around it.** A `.help` on a segmented `Picker`, or on
/// an ancestor of one, sets every segment's own tooltip to nil — including segments that carry
/// their own `.help`. Measured on macOS 26 by reading `NSSegmentedControl.toolTip(forSegment:)`
/// from a probe (the 19 October tooltip audit); SwiftUI accepts it without a warning.
/// `Scripts/check-tooltips.sh` refuses a `.help` on or just around one, as far as grep can see.
///
/// A segment's tooltip and spoken name are `help`, or its title when there is none. If a layout
/// ever needs a tooltip over the whole control, use `PageTabs`, whose plain buttons keep their own.
struct IconSegmentedPicker<Option: Hashable>: View {
    /// The control's name; hidden, as each segment speaks for itself.
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    let systemImage: (Option) -> String
    var help: ((Option) -> String)? = nil

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                let words = help?(option) ?? label(option)
                Label(label(option), systemImage: systemImage(option))
                    .labelStyle(.iconOnly)
                    .help(words)
                    .accessibilityLabel(words)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
