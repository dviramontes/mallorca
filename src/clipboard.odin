// macOS system pasteboard access, so copy/paste round-trips through the OS
// clipboard: a block copied inside mallorca can be pasted elsewhere, and an
// Orca pattern copied from anywhere (editor, terminal, web) pastes into the
// grid. The Foundation binding ships only a stub for NSPasteboard, so we send
// the two messages we need (generalPasteboard, stringForType:/setString:) by
// hand via the objc runtime.
#+build darwin
package main

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// The UTI for plain UTF-8 text — NSPasteboardTypeString.
@(private = "file")
PASTEBOARD_TYPE_STRING :: "public.utf8-plain-text"

// Read the general pasteboard as UTF-8 text. Returns ("", false) when it holds
// no string. The result is cloned into `allocator`; the caller owns it.
system_clipboard_read :: proc(allocator := context.allocator) -> (text: string, ok: bool) {
	pb := intrinsics.objc_send(^NS.Pasteboard, NS.Pasteboard, "generalPasteboard")
	if pb == nil {
		return "", false
	}
	ns := intrinsics.objc_send(^NS.String, pb, "stringForType:", NS.AT(PASTEBOARD_TYPE_STRING))
	if ns == nil {
		return "", false
	}
	s := ns->odinString()
	if len(s) == 0 {
		return "", false
	}
	return strings.clone(s, allocator), true
}

// Replace the general pasteboard's contents with `text`. Best-effort: a failed
// clear/set just leaves the internal clipboard as the source of truth.
system_clipboard_write :: proc(text: string) {
	pb := intrinsics.objc_send(^NS.Pasteboard, NS.Pasteboard, "generalPasteboard")
	if pb == nil {
		return
	}
	intrinsics.objc_send(NS.Integer, pb, "clearContents")
	ns := NS.String.alloc()->initWithOdinString(text)
	defer ns->release()
	intrinsics.objc_send(bool, pb, "setString:forType:", ns, NS.AT(PASTEBOARD_TYPE_STRING))
}
