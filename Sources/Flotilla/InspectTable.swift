import SwiftUI

/// The JSON/Table switch and the flattening behind it, shared by the container and machine
/// Inspect tabs.
///
/// Extracted rather than copied. `InspectRow` and the flatten walk lived inside
/// `ContainerDetailView`'s `private struct InspectTab`, so the machines side could not reach
/// them and shipped with a JSON view only — which is exactly how the two panels would have
/// drifted: a fix to one walk (empty arrays, `null`, ordering) would silently not apply to the
/// other. One implementation, two callers.
enum InspectPresentation: String, CaseIterable, Identifiable {
    case json = "JSON", table = "Table"
    var id: Self { self }
}

struct InspectRow: Identifiable {
    let id: Int
    let path: String
    let value: String
}

/// Flattens decoded JSON to `key.path[0] = value` leaves.
///
/// Empty objects and arrays are emitted as `{}` / `[]` rather than dropped: `capAdd: []` says
/// "no added capabilities", and a row that vanishes says nothing at all.
func flattenInspect(_ json: String?) -> [InspectRow] {
    guard let json, let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data)
    else { return [] }

    var leaves: [(String, String)] = []
    func walk(_ node: Any, _ path: String) {
        switch node {
        case let dict as [String: Any] where !dict.isEmpty:
            for key in dict.keys.sorted() {
                walk(dict[key]!, path.isEmpty ? key : "\(path).\(key)")
            }
        case let array as [Any] where !array.isEmpty:
            for (index, element) in array.enumerated() { walk(element, "\(path)[\(index)]") }
        case is [String: Any]: leaves.append((path, "{}"))
        case is [Any]: leaves.append((path, "[]"))
        case is NSNull: leaves.append((path, "null"))
        default: leaves.append((path, String(describing: node)))
        }
    }
    walk(root, "")
    return leaves.enumerated().map {
        InspectRow(id: $0.offset, path: $0.element.0, value: $0.element.1)
    }
}

/// One row per leaf, so you can scan for a value without reading the nesting.
///
/// Built from the **redacted** text the JSON view shows, never a second fetch — the two
/// presentations must not be able to disagree about what is hidden.
struct InspectTableView: View {
    let json: String?
    let search: String

    var body: some View {
        let rows = flattenInspect(json).filter {
            search.isEmpty
            || $0.path.localizedCaseInsensitiveContains(search)
            || $0.value.localizedCaseInsensitiveContains(search)
        }
        if rows.isEmpty {
            ContentUnavailableView(
                json == nil ? "Nothing loaded yet" : "No matching keys",
                systemImage: "tablecells"
            )
        } else {
            SwiftUI.Table(rows) {
                TableColumn("Key") { row in
                    Text(row.path).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                TableColumn("Value") { row in
                    Text(row.value).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
