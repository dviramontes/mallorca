package main

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// The icon bin/Mallorca.app ships in Contents/Resources, embedded so a bare
// bin/mallorca — run outside the bundle — gets the island in the Dock too.
// Inside the bundle AppKit already reads it via CFBundleIconFile; setting the
// same image again there is a no-op.
ICON_DATA :: #load("../assets/mallorca.icns")

// Must run after karl2d has created the NSApplication.
set_dock_icon :: proc() {
	data := NS.Data.alloc()->initWithBytes(ICON_DATA)
	defer data->release()

	// core:sys/darwin/Foundation binds neither -[NSImage initWithData:] nor
	// -[NSApplication setApplicationIconImage:], and its own msgSend is
	// private to the package, so send the selectors through the intrinsic.
	img := intrinsics.objc_send(^NS.Image, NS.Image.alloc(), "initWithData:", data)
	if img == nil {
		return
	}
	defer img->release()

	intrinsics.objc_send(nil, NS.Application.sharedApplication(), "setApplicationIconImage:", img)
}
