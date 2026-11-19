hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/lib/tsukuyomi/start-desktop")
end)

hl.layer_rule({
    name = "tsukuyomi-frost",
    match = { namespace = "^ryoku-(frame-edge|dock)$" },
    blur = true,
    ignore_alpha = 0.05,
})
