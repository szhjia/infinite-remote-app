import SwiftUI

struct SetupBanner: View {
    private struct Slide {
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    private static let slides: [Slide] = [
        .init(title: "用遥控器控制 Mac", detail: "连接兼容的蓝牙遥控器，把常用操作放到手边。",
              symbol: "desktopcomputer", tint: .blue),
        .init(title: "为每个按键选择动作", detail: "为单击选择动作，部分按键还支持双击和长按。",
              symbol: "keyboard", tint: .indigo),
        .init(title: "在应用之间切换", detail: "用遥控器切换运行中的应用。",
              symbol: "macwindow.on.rectangle", tint: .purple),
        .init(title: "打开常用媒体", detail: "用遥控器选择音乐和视频应用。",
              symbol: "play.rectangle", tint: .teal),
        .init(title: "按键开始听写", detail: "用遥控器触发 macOS 听写。",
              symbol: "waveform", tint: .blue)
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Int? = 0

    private var current: Int { position ?? 0 }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Self.slides.indices, id: \.self) { index in
                        slide(Self.slides[index], index: index)
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                            .accessibilityHidden(index != current)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position, anchor: .center)
            .scrollIndicators(.never)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                arrow("chevron.left", title: "上一张", destination: current - 1)
                HStack(spacing: 1) {
                    ForEach(Self.slides.indices, id: \.self) { index in
                        Button {
                            move(to: index)
                        } label: {
                            Circle()
                                .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.36))
                                .frame(width: 7, height: 7)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("第 %d 张，共 %d 张", index + 1, Self.slides.count))
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                    }
                }
                arrow("chevron.right", title: "下一张", destination: current + 1)
            }
        }
    }

    private func slide(_ slide: Slide, index: Int) -> some View {
        VStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.background.opacity(0.65))
                    .frame(width: 166, height: 108)
                Image(systemName: slide.symbol)
                    .font(.system(size: 58, weight: .light))
                    .foregroundStyle(slide.tint)
                    .accessibilityHidden(true)
                if index == 0 {
                    Image("BridgeBrand", bundle: .module)
                        .resizable().scaledToFit()
                        .frame(width: 43, height: 43)
                        .offset(x: 63, y: 40)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 138)
            .accessibilityHidden(true)
            Text(L10n.tr(slide.title)).font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(L10n.tr(slide.detail)).font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [slide.tint.opacity(0.17), slide.tint.opacity(0.045)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func arrow(_ symbol: String, title: String, destination: Int) -> some View {
        Button {
            move(to: destination)
        } label: {
            Image(systemName: symbol).frame(width: 18, height: 16)
        }
        .accessibilityLabel(L10n.tr(title))
        .disabled(!Self.slides.indices.contains(destination))
    }

    private func move(to index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { position = index }
    }
}
