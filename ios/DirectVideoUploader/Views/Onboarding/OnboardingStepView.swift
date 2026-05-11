// May 10, 2026 - 3:34pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

struct OnboardingStepView: View {
     let step: OnboardingStepDefinition
     let position: Int
     let total: Int

     var body: some View {
          ScrollView {
               VStack(alignment: .leading, spacing: Theme.space20) {
                    Spacer().frame(height: Theme.space24)

                    HStack {
                         Text("Step \(position) of \(total)")
                              .font(Theme.font13Semibold)
                              .foregroundStyle(Theme.secondaryText)
                              .padding(.horizontal, Theme.space12)
                              .padding(.vertical, Theme.space8)
                              .background(Theme.glassOverlay, in: Capsule())

                         Spacer()
                    }

                    VStack(alignment: .leading, spacing: Theme.space12) {
                         Image(systemName: step.icon)
                              .font(Theme.display44)
                              .foregroundStyle(Theme.purple)

                         Text(step.title)
                              .font(Theme.font28Bold)
                              .foregroundStyle(Theme.primaryText)

                         Text(step.summary)
                              .font(Theme.font16Regular)
                              .foregroundStyle(Theme.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: Theme.space12) {
                         ForEach(step.bullets, id: \.self) { bullet in
                              HStack(alignment: .top, spacing: Theme.space12) {
                                   Image(systemName: "checkmark.circle.fill")
                                        .font(Theme.icon16)
                                        .foregroundStyle(Theme.green)
                                        .padding(.top, 2)

                                   Text(bullet)
                                        .font(Theme.font16Regular)
                                        .foregroundStyle(Theme.lightText)
                              }
                         }
                    }
                    .padding(Theme.space16)
                    .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: Theme.radiusLg))

                    Spacer().frame(height: Theme.space24)
               }
               .padding(.horizontal, Theme.space24)
               .padding(.bottom, Theme.space32)
          }
     }
}
