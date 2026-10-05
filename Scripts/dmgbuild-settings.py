import os.path

# Injected via dmgbuild -D
application = defines["app"]
background = defines["background"]
appname = os.path.basename(application)

# dmgbuild writes the background reference straight into .DS_Store. On macOS 26
# that is the only path Finder reliably resolves — create-dmg styles the window
# with AppleScript, which fails silently here and leaves a blank background.
format = "UDZO"
filesystem = "APFS"

files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]

# The background PNG is exactly this window size at 72 DPI. A higher-DPI image
# renders at a fraction of the size and reads as "missing".
icon_size = 88
text_size = 12
window_rect = ((120, 120), (540, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_locations = {
    appname: (165, 205),
    "Applications": (395, 205),
    # dmgbuild drops the artwork at the volume root as a dotfile. It is hidden
    # in a default Finder, but anyone with "show hidden files" on — or a window
    # that has been toggled with cmd-shift-period — gets a PNG icon auto-placed
    # in the first free slot, right on top of the artwork. Parking it far
    # outside the window keeps it out of the way either way.
    ".background.png": (2000, 2000),
}
