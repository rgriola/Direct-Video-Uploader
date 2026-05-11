// May 10, 2026 - 3:34pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

struct OnboardingWalkthroughView: View {
     @Environment(\.dismiss) private var dismiss

     let onOpenGuide: () -> Void

     @State private var currentIndex = 0

     private let steps = OnboardingCatalog.steps

     var body: some View {
          ZStack {
               Theme.deepBg.ignoresSafeArea()

               VStack(spacing: 0) {
                    HStack {
                         Text("Welcome to Fixer")
                              .font(Theme.font20Bold)
                              .foregroundStyle(Theme.primaryText)

                         Spacer()

                         Button("Skip") {
                              complete(openGuide: false)
                         }
                         .font(Theme.font13Semibold)
                         .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, Theme.space20)
                    .padding(.top, Theme.space16)
                    .padding(.bottom, Theme.space8)

                    TabView(selection: $currentIndex) {
                         ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                              OnboardingStepView(
                                   step: step, position: index + 1, total: steps.count
                              )
                              .tag(index)
                         }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))

                    VStack(spacing: Theme.space12) {
                         Button {
                              advanceOrComplete()
                         } label: {
                              Text(currentIndex == steps.count - 1 ? "Start Uploading" : "Next")
                                   .font(Theme.font16Semibold)
                                   .foregroundStyle(Theme.white)
                                   .frame(maxWidth: .infinity)
                                   .padding(.vertical, Theme.space16)
                                   .background(Theme.purple)
                                   .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                         }

                         Button {
                              complete(openGuide: true)
                         } label: {
                              Text("Open Full Guide")
                                   .font(Theme.font13Medium)
                                   .foregroundStyle(Theme.secondaryText)
                                   .frame(maxWidth: .infinity)
                                   .padding(.vertical, Theme.space8)
                         }
                    }
                    .padding(.horizontal, Theme.space24)
                    .padding(.top, Theme.space8)
                    .padding(.bottom, Theme.space24)
               }
          }
          .interactiveDismissDisabled(!OnboardingCatalog.isCompleted)
     }

     private func advanceOrComplete() {
          guard currentIndex < steps.count - 1 else {
               complete(openGuide: false)
               return
          }

          withAnimation(.easeInOut(duration: 0.2)) {
               currentIndex += 1
          }
     }

     private func complete(openGuide: Bool) {
          OnboardingCatalog.markCompleted()
          dismiss()

          guard openGuide else { return }
          DispatchQueue.main.async {
               onOpenGuide()
          }
     }
}
