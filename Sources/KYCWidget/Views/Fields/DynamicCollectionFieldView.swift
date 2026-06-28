#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Dynamic Collection (repeatable group). The merchant defines `itemFields`
/// (the columns) once in the dashboard builder; the end user repeats them as N
/// rows. 1:1 with web `DynamicCollectionField.tsx` + Android
/// `DynamicCollectionFieldKyc`.
///
/// Rows live at `session.values[field.id]` as an array of `{ _rowId }` stubs.
/// Each row's child inputs render through the normal `FieldRenderer` under a
/// per-row key (`DynamicCollectionKeys.childFieldID`); the session's
/// `mirrorDynamicCollectionValues` folds those flat values back into the rows
/// array at validate/submit time — reusing every existing field renderer.
@available(iOS 15.0, *)
struct DynamicCollectionFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    @State private var seeded = false

    private var rowIDs: [String] {
        (session.values[field.id]?.arrayValue ?? [])
            .compactMap { $0.dictValue?["_rowId"]?.stringValue }
    }
    private var itemFields: [WidgetField] { field.itemFields ?? [] }
    private var effectiveMin: Int { max(field.minRows ?? 0, field.required ? 1 : 0) }
    private var atMax: Bool { field.maxRows != nil && rowIDs.count >= field.maxRows! }
    private var canDelete: Bool { field.allowDelete != false && rowIDs.count > effectiveMin }

    var body: some View {
        FieldShell(label: field.label, required: field.required, helper: nil, error: session.fieldErrors[field.id]) {
            VStack(alignment: .leading, spacing: 12) {
                if rowIDs.isEmpty {
                    Text("No entries yet.").font(.system(size: 13)).foregroundColor(.secondary)
                }
                ForEach(Array(rowIDs.enumerated()), id: \.element) { idx, rowID in
                    rowCard(idx: idx, rowID: rowID)
                }
                if field.allowAdd != false && !atMax {
                    addButton
                }
            }
        }
        .onAppear(perform: seedIfNeeded)
    }

    private func rowCard(idx: Int, rowID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(field.label) \(idx + 1)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if field.allowReorder != false {
                    iconButton("chevron.up", enabled: idx > 0) { move(idx, by: -1) }
                    iconButton("chevron.down", enabled: idx < rowIDs.count - 1) { move(idx, by: 1) }
                }
                if field.allowDuplicate != false {
                    iconButton("doc.on.doc", enabled: !atMax) { duplicate(idx: idx, rowID: rowID) }
                }
                if canDelete {
                    iconButton("trash", enabled: true, tint: .red) { remove(rowID) }
                }
            }
            ForEach(itemFields) { child in
                // Per-row child id keeps each row's inputs isolated in the flat
                // session map; the mirror folds them back at submit.
                FieldRenderer(
                    field: child.withID(DynamicCollectionKeys.childFieldID(field.id, rowID, child.name)),
                    session: session
                )
            }
        }
        .padding(12)
        .background(KYCBrand.canvas)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .cornerRadius(10)
    }

    private var addButton: some View {
        Button { commit(rowIDs + [UUID().uuidString]) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                Text("Add \(field.label)").font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(KYCBrand.primary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KYCBrand.primary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(KYCBrand.primary.opacity(0.4), lineWidth: 1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, enabled: Bool, tint: Color = .secondary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(enabled ? tint : Color.secondary.opacity(0.35))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Mutations

    private func commit(_ ids: [String]) {
        session.setValue(.array(ids.map { .object(["_rowId": .string($0)]) }), for: field.id)
    }

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        if rowIDs.isEmpty {
            let seed = max(field.defaultRows ?? 0, effectiveMin)
            if seed > 0 { commit((0..<seed).map { _ in UUID().uuidString }) }
        }
    }

    private func move(_ idx: Int, by offset: Int) {
        var ids = rowIDs
        let to = idx + offset
        guard to >= 0, to < ids.count else { return }
        let moved = ids.remove(at: idx)
        ids.insert(moved, at: to)
        commit(ids)
    }

    private func duplicate(idx: Int, rowID: String) {
        guard !atMax else { return }
        let newID = UUID().uuidString
        // Copy the source row's child values into the new row's keys.
        for child in itemFields {
            let src = DynamicCollectionKeys.childFieldID(field.id, rowID, child.name)
            if let v = session.values[src] {
                session.setValue(v, for: DynamicCollectionKeys.childFieldID(field.id, newID, child.name))
            }
        }
        var ids = rowIDs
        ids.insert(newID, at: idx + 1)
        commit(ids)
    }

    private func remove(_ rowID: String) {
        commit(rowIDs.filter { $0 != rowID })
    }
}
#endif
