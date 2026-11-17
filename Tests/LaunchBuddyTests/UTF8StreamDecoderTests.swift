import XCTest
@testable import LaunchBuddy

/// Exercises UTF8StreamDecoder in its contract: fed serially by the pipe
/// reader, a multi-byte character split across reads must be held back
/// until it is complete, invalid bytes must surface as U+FFFD without
/// losing the surrounding text, and the held tail at end-of-stream is
/// returned by flush().
final class UTF8StreamDecoderTests: XCTestCase {

    /// Decodes `chunks` in order and collects the non-nil results.
    private func decodeAll(_ decoder: UTF8StreamDecoder, _ chunks: [[UInt8]]) -> [String] {
        chunks.compactMap { decoder.decode(Data($0)) }
    }

    // MARK: - Plain text

    func test_ascii_is_decoded_per_chunk() {
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0x48, 0x65])), "He")
        XCTAssertEqual(d.decode(Data([0x6C, 0x6C, 0x6F])), "llo")
    }

    func test_empty_data_returns_nil() {
        let d = UTF8StreamDecoder()
        XCTAssertNil(d.decode(Data()))
    }

    func test_crlf_bytes_pass_through_untouched() {
        // The decoder is text-level: it must preserve \r and \n; line
        // splitting is the caller's job.
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0x61, 0x0D])), "a\r")
        XCTAssertEqual(d.decode(Data([0x0A])), "\n")
    }

    // MARK: - Multi-byte characters split across chunks

    func test_two_byte_char_split_across_chunks() {
        // é = C3 A9
        let d = UTF8StreamDecoder()
        XCTAssertNil(d.decode(Data([0xC3])), "lone lead byte must be held back")
        XCTAssertEqual(d.decode(Data([0xA9])), "é")
    }

    func test_three_byte_char_split_one_byte_at_a_time() {
        // € = E2 82 AC
        let d = UTF8StreamDecoder()
        XCTAssertNil(d.decode(Data([0xE2])))
        XCTAssertNil(d.decode(Data([0x82])))
        XCTAssertEqual(d.decode(Data([0xAC])), "€")
    }

    func test_four_byte_char_split_one_byte_at_a_time() {
        // 👍 = F0 9F 91 8D
        let d = UTF8StreamDecoder()
        XCTAssertNil(d.decode(Data([0xF0])))
        XCTAssertNil(d.decode(Data([0x9F])))
        XCTAssertNil(d.decode(Data([0x91])))
        XCTAssertEqual(d.decode(Data([0x8D])), "👍")
    }

    func test_split_char_after_text_in_same_chunk() {
        // "a" + lead of é in one chunk, tail in the next.
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0x61, 0xC3])), "a")
        XCTAssertEqual(d.decode(Data([0xA9])), "é")
    }

    func test_split_char_in_middle_of_stream() {
        // "a" + € (E2 82 AC) split between bytes 2 and 3.
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0x61, 0xE2, 0x82])), "a")
        XCTAssertEqual(d.decode(Data([0xAC, 0x62])), "€b")
    }

    // MARK: - Invalid bytes

    func test_invalid_byte_becomes_replacement_character() {
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0x61, 0xFF, 0x62])), "a\u{FFFD}b")
    }

    func test_invalid_byte_before_complete_sequence() {
        // FF is invalid, but the C3 lead must still be held back rather
        // than replaced, so the following A9 can complete it.
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0xFF, 0xC3])), "\u{FFFD}")
        XCTAssertEqual(d.decode(Data([0xA9])), "é")
    }

    func test_stray_continuation_byte_is_replaced_not_held() {
        // A continuation byte cannot start a sequence, so it is invalid,
        // not a held-back partial sequence.
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0xA9])), "\u{FFFD}")
    }

    func test_mixed_valid_and_invalid() {
        // a + é (valid) + stray A9
        let d = UTF8StreamDecoder()
        XCTAssertEqual(d.decode(Data([0x61, 0xC3, 0xA9, 0xA9])), "aé\u{FFFD}")
    }

    // MARK: - flush() at end of stream

    func test_flush_returns_held_tail_with_replacement() {
        // Stream ends with an incomplete sequence: the held bytes must be
        // surfaced (as U+FFFD), not lost.
        let d = UTF8StreamDecoder()
        XCTAssertNil(d.decode(Data([0xC3])))
        XCTAssertEqual(d.flush(), "\u{FFFD}")
    }

    func test_flush_decodes_incomplete_sequence_with_replacement() {
        // An incomplete 4-byte sequence at end of stream is one maximal
        // ill-formed subsequence, hence a single U+FFFD.
        let d = UTF8StreamDecoder()
        XCTAssertNil(d.decode(Data([0xF0, 0x9F, 0x91])))
        XCTAssertEqual(d.flush(), "\u{FFFD}")
    }

    func test_flush_on_empty_decoder_returns_nil() {
        let d = UTF8StreamDecoder()
        XCTAssertNil(d.flush())
        d.decode(Data([0x61]))
        XCTAssertNil(d.flush(), "fully decoded buffer must be empty")
    }
}
