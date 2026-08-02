import SwiftUI

/// 频道详情:头部(封面/标题/作者/订阅)+ 分集列表。
struct PodcastDetailView: View {
    let podcast: Podcast

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController

    @State private var episodes: [Episode] = []
    @State private var loaded: Podcast?
    @State private var loading = false

    private var display: Podcast { loaded ?? podcast }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    .listRowSeparator(.hidden)
            }
            if loading && episodes.isEmpty {
                ContentUnavailableViewCompat(loading: true, text: "")
            } else if episodes.isEmpty {
                ContentUnavailableViewCompat(loading: false, text: "暂无单集")
            } else {
                Section("单集") {
                    ForEach(episodes) { ep in
                        EpisodeRow(episode: ep,
                                   isCurrent: player.current?.id == ep.id,
                                   isPlaying: player.isPlaying,
                                   onPlay: { player.playOrToggle(ep, queue: episodes) })
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(display.title)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Artwork(url: display.artworkUrl, size: 120, corner: 14)
            VStack(alignment: .leading, spacing: 8) {
                Text(display.title).font(.title2.bold()).lineLimit(3)
                if !display.author.isEmpty {
                    Text(display.author).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                subscribeButton
                if !display.description.isEmpty {
                    Text(display.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    private var subscribeButton: some View {
        let subscribed = env.subscriptions.isSubscribed(display.id)
        return Button {
            env.subscriptions.toggle(display)
        } label: {
            Label(subscribed ? "已订阅" : "订阅",
                  systemImage: subscribed ? "checkmark" : "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    private func load() async {
        guard episodes.isEmpty else { return }
        loading = true
        if let result = await env.repository.feed(podcast.feedUrl) {
            loaded = result.podcast
            episodes = result.episodes
        }
        loading = false
    }
}
