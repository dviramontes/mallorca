#+build darwin
package main

import "core:testing"

@(test)
test_midi_channel_targets :: proc(t: ^testing.T) {
	targets, count := midi_channel_targets(0)
	testing.expect_value(t, count, 16)
	for channel in u8(0) ..< 16 {
		testing.expect_value(t, targets[channel], channel)
	}

	targets, count = midi_channel_targets(1)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, targets[0], u8(0))

	targets, count = midi_channel_targets(2)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, targets[0], u8(1))

	targets, count = midi_channel_targets(15)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, targets[0], u8(14))
}
