//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// ADR-0063 §4.5 / §7.4: `Preview.rich` (field 1000) travels with a message as bytes. A received value is kept as it
/// arrived — fields this build does not know included — in `OWSLinkPreview.rich`, and goes out again unchanged when
/// the message is forwarded. It is never trimmed against the registry of the day; which card it becomes is decided at
/// render time (§5.1).
///
/// "As it arrived": SwiftProtobuf keeps every field it does not know in `unknownFields` and writes those back after the
/// known ones, so re-serializing what it parsed gives back the received bytes for any encoder that writes fields in
/// ascending order (prost, Wire, SwiftProtobuf and protopiler do).
public enum TellomiRichContent {

    /// The bytes of a received `Preview.rich`, or nil when the preview has none.
    public static func receivedBytes(_ preview: SSKProtoPreview) -> Data? {
        guard let rich = preview.rich else {
            return nil
        }
        do {
            return try rich.serializedData()
        } catch {
            owsFailDebug("Could not serialize rich content: \(error)")
            return nil
        }
    }

    /// The `RichContent` to put on an outgoing `Preview`. Nil — the field stays absent and the preview serializes byte
    /// for byte as it did before the field existed — when there are no bytes, or when stored bytes no longer parse:
    /// the snapshot (fields 1–5) always stands on its own, so a bad value never fails the send (§7.1).
    public static func forSending(_ bytes: Data?) -> SSKProtoRichContent? {
        guard let bytes else {
            return nil
        }
        do {
            return try SSKProtoRichContent(serializedData: bytes)
        } catch {
            Logger.warn("Dropping unparsable rich content (\(bytes.count) bytes): \(error)")
            return nil
        }
    }
}
