import SwiftUI

/// The floating search field at the top of the map.
struct SearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isSearching: Bool
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Search a place or city", text: $text)
                .focused(isFocused)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }

            Divider().frame(height: 22)

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .floatingPanel(cornerRadius: 25)
    }
}

/// One-tap category searches ("Restaurants", "Parks", …).
struct QuickSearchChips: View {
    let onSelect: (QuickSearch) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickSearch.all) { quick in
                    Button {
                        onSelect(quick)
                    } label: {
                        Label(quick.title, systemImage: quick.symbolName)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .floatingPanel(cornerRadius: 17)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6) // room for shadows
        }
        .padding(.horizontal, -16)
    }
}

/// Shown while typing: recent searches and ideas.
struct SearchSuggestions: View {
    let recentSearches: [String]
    let onSelect: (String) -> Void
    let onClearRecent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !recentSearches.isEmpty {
                HStack {
                    Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", action: onClearRecent).font(.footnote)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

                ForEach(recentSearches.prefix(5), id: \.self) { query in
                    row(query, symbol: "clock.arrow.circlepath")
                }
            }

            Text("Try")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(QuickSearch.examples, id: \.self) { query in
                row(query, symbol: "sparkle.magnifyingglass")
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingPanel()
    }

    private func row(_ query: String, symbol: String) -> some View {
        Button {
            onSelect(query)
        } label: {
            Label(query, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
