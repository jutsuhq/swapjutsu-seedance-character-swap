import Foundation

/// An API-format ComfyUI graph ("Save (API Format)"): node id → `{class_type, inputs}`.
public struct Workflow: Sendable, Equatable {
    public var nodes: [String: JSONValue]

    public init(nodes: [String: JSONValue]) { self.nodes = nodes }

    /// Refuses the UI format (`nodes` / `links` arrays), which the API rejects as `workflow_format_ui`.
    public init(apiFormat data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = value.object else { throw ComfyError.invalidWorkflow("A workflow must be a JSON object.") }
        if case .array = object["nodes"], case .array = object["links"] {
            throw ComfyError.invalidWorkflow("This is a UI-format workflow; export it with Save (API Format).")
        }
        nodes = object
    }

    public subscript(input field: String, of node: String) -> JSONValue? {
        get { nodes[node]?["inputs"]?[field] }
        set { nodes[node]?["inputs"]?[field] = newValue }
    }

    /// A link from another node's output, `[node, index]`.
    public static func link(_ node: String, _ output: Int = 0) -> JSONValue {
        [.string(node), .number(Double(output))]
    }

    /// The reference that stands in for a file name where a loader node takes an uploaded input.
    public static func reference(to asset: Asset) -> JSONValue {
        ["__type": "core/ASSET", "info": ["id": .string(asset.id)]]
    }
}
