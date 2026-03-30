import SwiftUI

// MARK: - Overview
//
// `WithAttachments` resolves attachment references in an `AttributedString`.
//
// Markup parsing keeps some items as URL attributes:
// - `run.imageURL` for images
// - `run.textual.emojiURL` for custom emoji references emitted by pattern expansion
//
// This view asynchronously loads those URLs using the environment-provided attachment loaders and
// writes the resolved attachments back into the attributed string as `Textual.Attachment`
// attributes. The rest of the rendering pipeline treats attachment runs like any other span.

struct WithAttachments<Content: View>: View {
  @Environment(\.imageAttachmentLoader) private var imageAttachmentLoader
  @Environment(\.emojiAttachmentLoader) private var emojiAttachmentLoader
  @Environment(\.colorEnvironment) private var colorEnvironment

  @State private var model = Model()

  private let attributedString: AttributedString
  private let content: (AttributedString) -> Content

  init(
    _ attributedString: AttributedString,
    @ViewBuilder content: @escaping (AttributedString) -> Content
  ) {
    self.attributedString = attributedString
    self.content = content
  }

  var body: some View {
    content(model.resolvedAttributedString ?? attributedString)
      .task(id: attributedString) {
        await model.resolveAttachments(
          in: attributedString,
          imageAttachmentLoader: imageAttachmentLoader,
          emojiAttachmentLoader: emojiAttachmentLoader,
          environment: colorEnvironment
        )
      }
  }
}

extension WithAttachments {
  @MainActor @Observable final class Model {
    var resolvedAttributedString: AttributedString?

    /// Caches previously resolved attachments by URL to avoid redundant loads during streaming.
    private var attachmentCache: [URL: AnyAttachment] = [:]

    func resolveAttachments(
      in attributedString: AttributedString,
      imageAttachmentLoader: any AttachmentLoader,
      emojiAttachmentLoader: any AttachmentLoader,
      environment: ColorEnvironmentValues
    ) async {
      guard attributedString.containsValues(for: [\.imageURL, \.textual.emojiURL]) else {
        return
      }

      var attachments: [AnyAttachment] = []
      var ranges: [Range<AttributedString.Index>] = []

      // Apply cached attachments immediately; collect uncached URLs for async loading
      var uncachedRuns: [(url: URL, isEmoji: Bool, range: Range<AttributedString.Index>)] = []

      for run in attributedString.runs {
        if let imageURL = run.imageURL {
          if let cached = attachmentCache[imageURL] {
            attachments.append(cached)
            ranges.append(run.range)
          } else {
            uncachedRuns.append((url: imageURL, isEmoji: false, range: run.range))
          }
        } else if let emojiURL = run.textual.emojiURL {
          if let cached = attachmentCache[emojiURL] {
            attachments.append(cached)
            ranges.append(run.range)
          } else {
            uncachedRuns.append((url: emojiURL, isEmoji: true, range: run.range))
          }
        }
      }

      if !uncachedRuns.isEmpty {
        await withTaskGroup(
          of: (URL, AnyAttachment?, Range<AttributedString.Index>).self
        ) { group in
          for item in uncachedRuns {
            let loader = item.isEmoji ? emojiAttachmentLoader : imageAttachmentLoader
            group.addTask {
              let attachment = try? await loader.attachment(
                for: item.url,
                text: String(attributedString[item.range].characters[...]),
                environment: environment
              )
              return (item.url, attachment.map(AnyAttachment.init), item.range)
            }
          }

          for await (url, attachment, range) in group {
            guard let attachment else { continue }

            attachmentCache[url] = attachment
            attachments.append(attachment)
            ranges.append(range)
          }
        }
      }

      resolveAttachmentsFinished(
        attributedString: attributedString,
        attachments: Array(zip(ranges, attachments))
      )
    }

    private func resolveAttachmentsFinished(
      attributedString: AttributedString,
      attachments: [(Range<AttributedString.Index>, AnyAttachment)]
    ) {
      var attributedString = attributedString

      for (range, attachment) in attachments {
        attributedString[range].textual.attachment = attachment
      }

      self.resolvedAttributedString = attributedString
    }
  }
}
