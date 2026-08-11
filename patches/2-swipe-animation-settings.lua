local ok, err = pcall(function()
    local Device = require("device")

    -- Force-enable the software swipe animation capability.
    -- The generic framebuffer has no hardware animation support, but the
    -- software animation is driven by the core patch's *Imp interception
    -- (see 2-swipe-animation-core.lua): once ReaderView:onPageChangeAnimation
    -- sets Screen.swipe_animations, our wrapped refresh*Imp takes over the
    -- refresh. We always claim the capability to expose the
    -- "Page turn animations" toggle and keep the PageChangeAnimation event
    -- plumbing active. On non-touch devices (Kindle 4) this is what makes
    -- the entity page-turn keys drive the animation in the first place.
    Device.canDoSwipeAnimation = function()
        return true
    end

    -- Default the page-turn animation to ON.
    -- On the Kindle 4 there is no touch gesture to discover it, and the stock
    -- "Page turn animations" toggle (Settings -> Page turns) defaults to OFF
    -- (G_reader_settings:flipNilOrFalse -> nil == off), so the user would
    -- otherwise see no animation at all. We only set it when the user has not
    -- made an explicit choice (readSetting == nil), so an explicit OFF/ON is
    -- always respected on later toggles / restarts.
    if G_reader_settings:readSetting("swipe_animations") == nil then
        G_reader_settings:saveSetting("swipe_animations", true)
    end

    local ReaderMenu = require("apps/reader/modules/readermenu")
    local Screen = Device.screen
    local UIManager = require("ui/uimanager")
    local T = require("ffi/util").template

    -- Localized strings. English is the gettext source language; until these
    -- strings are added to KOReader's l10n catalogs, provide a built-in
    -- Chinese / Portuguese (Brazil) translation so both locales read fine.
    local GetText = require("gettext")
    local interface_lang = G_reader_settings:readSetting("language") or ""
    local zh_ui = interface_lang:match("^zh") and true or false
    local pt_BR_ui = interface_lang:match("^pt_BR") and true or false

    local zh_fallback = {
        ["Animation frame delay"] = "动画帧延迟",
        ["Animation steps"] = "动画段数",
        ["Cancel"] = "取消",
        ["Restore default"] = "恢复默认",
        ["Save"] = "保存",
        ["Swipe animation refresh mode"] = "翻页动画刷新模式",
        ["UI refresh"] = "UI刷新",
        ["UI refresh (default, recommended)"] = "UI刷新（默认，推荐）",
        ["Fast refresh (default, recommended)"] = "Fast刷新（默认，推荐）",
        ["Fast refresh (fastest, more ghosting)"] = "Fast刷新（最快，易残影）",
        ["Animation engine"] = "动画引擎",
        ["Zero-copy (recommended, fastest)"] = "零拷贝（推荐，最快）",
        ["Buffered (compatible, slower)"] = "缓冲区兼容（兼容，较慢）",
        ["Use einkfb fast refresh (fx_update_fast)"] = "使用 einkfb 快速刷新（fx_update_fast）",
        ["%1 animation frame delay: %2 ms"] = "%1动画帧延迟：%2 毫秒",
        ["%1 animation frame delay: default %2 ms"] = "%1动画帧延迟：默认 %2 毫秒",
        ["%1 animation steps: %2"] = "%1动画段数：%2",
        ["%1 animation steps: default %2"] = "%1动画段数：默认 %2",
        ["Swipe animation settings"] = "翻页动画设置",
        ["Landscape"] = "横屏",
        ["Portrait"] = "竖屏",
        [ [[
Enter the delay between animation frames, in milliseconds.

Lower values are faster but may cause more ghosting.
Higher values are slower but usually look cleaner.

Current orientation: %1
Current default: %2 ms]] ] = [[
输入每一帧之间的延迟，单位为毫秒。

数值越低，速度越快，但可能残影更明显。
数值越高，速度越慢，但显示可能更干净。

当前保存方向：%1
当前默认值：%2 毫秒]],
        [ [[
Choose the refresh type used for each strip of the software swipe animation.

• UI refresh: balanced quality and speed, suitable for most cases.
• Fast refresh: fastest, best for smoothness when some ghosting is acceptable.

Changes take effect immediately.]] ] = [[
选择软件翻页动画中，每一小条画面更新时使用的刷新类型。

• UI刷新：平衡画质与速度，适合大多数情况。
• Fast刷新：速度最快，适合追求流畅度但可接受较多残影的场景。

更改后立即生效。]],
        [ [[
Adjust the pause between animation frames.

Enter a value in milliseconds. Portrait and landscape remember their own values.
When unset, the default for the current orientation is shown.]] ] = [[
调整翻页动画每一帧之间的停顿时间。

直接输入毫秒数即可。竖屏和横屏会分别记住各自的数值。未自定义时，会显示当前方向使用的默认值。]],
        [ [[
Enter the number of wipe strips used to build the animation.

Fewer strips = faster, coarser wipe. More strips = slower, smoother wipe.
Portrait and landscape remember their own values. When unset, the default
for the current orientation is shown.

On the Kindle 4 (Pearl eink), 2-4 strips is a good balance.]] ] = [[
输入擦除动画使用的条带数量。

条带越少，动画越快、擦除越生硬；条带越多，动画越慢、擦除越平滑。
竖屏和横屏会分别记住各自的数值。未自定义时，会显示当前方向使用的默认值。

在 Kindle 4（Pearl 电子墨水屏）上，2~4 段通常是速度与观感的平衡点。]],
        [ [[
Choose the animation engine.

• Zero-copy (recommended): sends strip refreshes directly. Fastest, and the
  only safe choice on Kindle 4 (the blitbuffer slow path would otherwise stall).
• Buffered: restores the previous page and blits strips back. Only needed on
  framebuffer backends that do not paint straight to the panel (e.g. SDL/
  emulator). On Kindle 4 it is much slower and may stall under rotation.

Changes take effect on the next page turn.]] ] = [[
选择动画引擎。

• 零拷贝（推荐）：直接发送条带刷新。速度最快，也是 Kindle 4 上唯一安全的
  选择（缓冲区方案会走上层的逐像素慢路径，可能卡死）。
• 缓冲区兼容：还原上一页并把条带逐条贴回。仅适用于不直接绘到面板的
  framebuffer 后端（如 SDL / 模拟器）。在 Kindle 4 上明显更慢，旋转时可能卡死。

更改将在下一次翻页时生效。]],
        [ [[
Use the einkfb fx_update_fast waveform for the strip refreshes instead of the
default partial waveform.

On the Kindle 4 this is much faster (Pearl partial is ~400-500 ms per strip).
If your kernel rejects the fast waveform, KOReader automatically falls back to
partial and this toggle has no further effect.]] ] = [[
对条带刷新使用 einkfb 的 fx_update_fast 波形，取代默认的 partial 波形。

在 Kindle 4 上这会快很多（Pearl 屏 partial 每次条带约 400~500 毫秒）。
若你的内核拒绝了 fast 波形，KOReader 会自动回退到 partial，此后此开关不再生效。]],
    }
    local pt_BR_fallback = {
        ["Animation frame delay"] = "Intervalo entre quadros da animação",
        ["Animation steps"] = "Segmentos da animação",
        ["Cancel"] = "Cancelar",
        ["Restore default"] = "Restaurar padrão",
        ["Save"] = "Salvar",
        ["Swipe animation refresh mode"] = "Modo de atualização da animação de deslizar",
        ["UI refresh"] = "Atualização da interface",
        ["UI refresh (default, recommended)"] = "Atualização da interface (padrão, recomendado)",
        ["Fast refresh (default, recommended)"] = "Atualização rápida (padrão, recomendado)",
        ["Fast refresh (fastest, more ghosting)"] = "Atualização rápida (mais veloz, mais ghosting)",
        ["Animation engine"] = "Motor da animação",
        ["Zero-copy (recommended, fastest)"] = "Cópia zero (recomendado, mais veloz)",
        ["Buffered (compatible, slower)"] = "Com buffer (compatível, mais lento)",
        ["Use einkfb fast refresh (fx_update_fast)"] = "Usar atualização rápida einkfb (fx_update_fast)",
        ["%1 animation frame delay: %2 ms"] = "%1 - intervalo entre quadros: %2 ms",
        ["%1 animation frame delay: default %2 ms"] = "%1 - intervalo entre quadros: padrão (%2 ms)",
        ["%1 animation steps: %2"] = "%1 - segmentos da animação: %2",
        ["%1 animation steps: default %2"] = "%1 - segmentos da animação: padrão (%2)",
        ["Swipe animation settings"] = "Configurações da animação de deslizar",
        ["Landscape"] = "Modo paisagem",
        ["Portrait"] = "Modo retrato",
        [ [[
Enter the delay between animation frames, in milliseconds.

Lower values are faster but may cause more ghosting.
Higher values are slower but usually look cleaner.

Current orientation: %1
Current default: %2 ms]] ] = [[
Insira o intervalo entre quadros da animação, em milissegundos.

Valores menores são mais rápidos, mas podem gerar mais ghosting.
Valores maiores são mais lentos, mas geralmente resultam em imagens mais limpas.

Orientação atual: %1
Padrão da orientação atual: %2 ms]],
        [ [[
Choose the refresh type used for each strip of the software swipe animation.

• UI refresh: balanced quality and speed, suitable for most cases.
• Fast refresh: fastest, best for smoothness when some ghosting is acceptable.

Changes take effect immediately.]] ] = [[
Escolha o tipo de atualização utilizado para cada segmento da animação de deslizar por software.

• Atualização da interface: qualidade e velocidade balanceadas, apropriada para a maioria dos casos.
• Atualização rápida: mais rápida, melhor para a suavização quando pouco ghosting é aceitável.

As alterações são aplicadas imediatamente.]],
        [ [[
Adjust the pause between animation frames.

Enter a value in milliseconds. Portrait and landscape remember their own values.
When unset, the default for the current orientation is shown.]] ] = [[
Ajusta a pausa entre quadros da animação.

Insira um valor em milissegundos. Os modos retrato e paisagem memorizam seus respectivos valores.
Quando inalterado, o padrão para a orientação atual é exibido.]],
        [ [[
Enter the number of wipe strips used to build the animation.

Fewer strips = faster, coarser wipe. More strips = slower, smoother wipe.
Portrait and landscape remember their own values. When unset, the default
for the current orientation is shown.

On the Kindle 4 (Pearl eink), 2-4 strips is a good balance.]] ] = [[
Insira o número de faixas de limpeza usadas para construir a animação.

Menos faixas = mais rápido, limpeza mais grossa. Mais faixas = mais lento, limpeza mais suave.
Os modos retrato e paisagem memorizam seus respectivos valores. Quando inalterado, o padrão
para a orientação atual é exibido.

No Kindle 4 (eink Pearl), 2 a 4 faixas é um bom equilíbrio.]],
        [ [[
Choose the animation engine.

• Zero-copy (recommended): sends strip refreshes directly. Fastest, and the
  only safe choice on Kindle 4 (the blitbuffer slow path would otherwise stall).
• Buffered: restores the previous page and blits strips back. Only needed on
  framebuffer backends that do not paint straight to the panel (e.g. SDL/
  emulator). On Kindle 4 it is much slower and may stall under rotation.

Changes take effect on the next page turn.]] ] = [[
Escolha o motor da animação.

• Cópia zero (recomendado): envia atualizações de faixas diretamente. Mais rápido, e a
  única escolha segura no Kindle 4 (o caminho lento do blitbuffer poderia travar).
• Com buffer: restaura a página anterior e cola as faixas de volta. Necessário apenas em
  backends de framebuffer que não pintam direto no painel (ex.: SDL/emulador). No Kindle 4
  é muito mais lento e pode travar sob rotação.

As alterações são aplicadas na próxima virada de página.]],
        [ [[
Use the einkfb fx_update_fast waveform for the strip refreshes instead of the
default partial waveform.

On the Kindle 4 this is much faster (Pearl partial is ~400-500 ms per strip).
If your kernel rejects the fast waveform, KOReader automatically falls back to
partial and this toggle has no further effect.]] ] = [[
Usa a forma de onda fx_update_fast do einkfb para as atualizações de faixas em vez da
forma de onda parcial padrão.

No Kindle 4 isso é muito mais rápido (partial Pearl é ~400-500 ms por faixa).
Se seu kernel rejeitar a forma de onda rápida, o KOReader volta automaticamente para
partial e este alternador não tem mais efeito.]],
    }

    local function _(msgid)
        local translated = GetText(msgid)
        if translated ~= msgid then
            return translated
        end
        if zh_ui then
            local zh = zh_fallback[msgid]
            if zh then
                return zh
            end
        end
        if pt_BR_ui then
            local pt_BR = pt_BR_fallback[msgid]
            if pt_BR then
                return pt_BR
            end
        end
        return msgid
    end

    if ReaderMenu._swipe_animation_settings_patch_applied then
        return
    end
    ReaderMenu._swipe_animation_settings_patch_applied = true

    -- One-time legacy setting migration (runs only once when patch loads)
    do
        local legacy_delay_ms = tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms")) or 0
        if legacy_delay_ms > 0 then
            if (tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms_vertical")) or 0) <= 0 then
                G_reader_settings:saveSetting("swipe_animation_delay_ms_vertical", legacy_delay_ms)
            end
            if (tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms_horizontal")) or 0) <= 0 then
                G_reader_settings:saveSetting("swipe_animation_delay_ms_horizontal", legacy_delay_ms)
            end
            G_reader_settings:delSetting("swipe_animation_delay_ms")
        end
        local legacy_steps = tonumber(G_reader_settings:readSetting("swipe_animation_steps")) or 0
        if legacy_steps > 0 then
            if (tonumber(G_reader_settings:readSetting("swipe_animation_steps_vertical")) or 0) <= 0 then
                G_reader_settings:saveSetting("swipe_animation_steps_vertical", legacy_steps)
            end
            if (tonumber(G_reader_settings:readSetting("swipe_animation_steps_horizontal")) or 0) <= 0 then
                G_reader_settings:saveSetting("swipe_animation_steps_horizontal", legacy_steps)
            end
            G_reader_settings:delSetting("swipe_animation_steps")
        end
    end

    local function isLandscapeScreen()
        return Screen.bb:getWidth() > Screen.bb:getHeight()
    end

    -- Simplified defaults come from UIManager.swipe_animation_defaults
    -- (the single source of truth for the animation tuning, set by the core patch).
    local function getAnimationDefaults()
        return (UIManager.swipe_animation_defaults or {})
    end

    local function getAutomaticSwipeAnimationDelayMs()
        local delay_defaults = getAnimationDefaults().delay_ms or {}
        if isLandscapeScreen() then
            return delay_defaults.landscape or 10
        else
            return delay_defaults.portrait or 20
        end
    end

    local function getAutomaticSwipeAnimationSteps()
        local steps_defaults = getAnimationDefaults().steps or {}
        if isLandscapeScreen() then
            return steps_defaults.landscape or 6
        else
            return steps_defaults.portrait or 8
        end
    end

    local function getSwipeAnimationDelaySettingKey()
        if isLandscapeScreen() then
            return "swipe_animation_delay_ms_horizontal", _("Landscape")
        end
        return "swipe_animation_delay_ms_vertical", _("Portrait")
    end

    local function getSwipeAnimationStepsSettingKey()
        if isLandscapeScreen() then
            return "swipe_animation_steps_horizontal", _("Landscape")
        end
        return "swipe_animation_steps_vertical", _("Portrait")
    end

    local function getConfiguredSwipeAnimationDelayMs()
        local key = getSwipeAnimationDelaySettingKey()
        local delay_ms = tonumber(G_reader_settings:readSetting(key)) or 0
        if delay_ms <= 0 then
            delay_ms = tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms")) or 0
        end
        if delay_ms > 0 then
            return delay_ms
        end
        return nil
    end

    local function saveConfiguredSwipeAnimationDelayMs(delay_ms)
        local key = getSwipeAnimationDelaySettingKey()
        if delay_ms and delay_ms > 0 then
            G_reader_settings:saveSetting(key, delay_ms)
        else
            G_reader_settings:delSetting(key)
        end
    end

    local function getConfiguredSwipeAnimationSteps()
        local key = getSwipeAnimationStepsSettingKey()
        local steps = tonumber(G_reader_settings:readSetting(key)) or 0
        if steps <= 0 then
            steps = tonumber(G_reader_settings:readSetting("swipe_animation_steps")) or 0
        end
        if steps > 0 then
            return steps
        end
        return nil
    end

    local function saveConfiguredSwipeAnimationSteps(steps)
        local key = getSwipeAnimationStepsSettingKey()
        if steps and steps >= 1 then
            G_reader_settings:saveSetting(key, math.floor(steps))
        else
            G_reader_settings:delSetting(key)
        end
    end

    -- ==================== Refresh mode for software swipe animation ====================
    -- Allows user to choose between "ui" and "fast" for the strip refreshes
    -- implemented in UIManager:_repaint. The implicit default follows the
    -- device profile (set by the core patch): "fast" on legacy Kindle (where
    -- we install fx_update_fast), "ui" elsewhere.
    local function getSwipeAnimationRefreshMode()
        local mode = G_reader_settings:readSetting("swipe_animation_refresh_mode")
        if mode ~= "ui" and mode ~= "fast" then
            mode = getAnimationDefaults().refresh_mode or "ui"
        end
        return mode
    end

    local function saveSwipeAnimationRefreshMode(mode)
        if mode == "ui" or mode == "fast" then
            G_reader_settings:saveSetting("swipe_animation_refresh_mode", mode)
        end
    end

    -- ==================== Animation engine ====================
    -- zerocopy (default, recommended): send strip refreshes directly, no buffer
    -- copy. buffer: restore previous page and blit strips back (for framebuffer
    -- backends that do not paint straight to the panel, e.g. SDL / emulator).
    local function getSwipeAnimationEngine()
        local e = G_reader_settings:readSetting("swipe_animation_engine")
        if e ~= "buffer" and e ~= "zerocopy" then
            e = "zerocopy"
        end
        return e
    end

    local function saveSwipeAnimationEngine(e)
        if e == "buffer" then
            G_reader_settings:saveSetting("swipe_animation_engine", "buffer")
        else
            G_reader_settings:delSetting("swipe_animation_engine")
        end
        if UIManager.swipe_animation_setNeedSnapshot then
            UIManager.swipe_animation_setNeedSnapshot(e == "buffer")
        end
    end

    -- ==================== einkfb fast refresh (legacy Kindle only) ====================
    local function isLegacyKindle()
        return getAnimationDefaults().is_legacy_kindle == true
    end

    local function isEinkfbFastEnabled()
        return G_reader_settings:nilOrTrue("swipe_animation_einkfb_fast")
    end

    local function toggleEinkfbFast()
        local enabled = not isEinkfbFastEnabled()
        if enabled then
            G_reader_settings:saveSetting("swipe_animation_einkfb_fast", true)
        else
            G_reader_settings:delSetting("swipe_animation_einkfb_fast")
        end
    end

    local function showNumberInputDialog(touchmenu_instance, title, value, default_value,
                                         orientation_label, description, on_save)
        local InputDialog = require("ui/widget/inputdialog")
        local input_dialog
        input_dialog = InputDialog:new{
            title = title,
            input = tostring(value),
            input_type = "number",
            description = T(description, orientation_label, default_value),
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = _("Restore default"),
                        callback = function()
                            on_save(nil)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local v = tonumber(input_dialog:getInputValue())
                            on_save(v)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            UIManager:close(input_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    local function showSwipeAnimationDelayInputDialog(touchmenu_instance)
        local current_value = tostring(getConfiguredSwipeAnimationDelayMs() or getAutomaticSwipeAnimationDelayMs())
        local orientation_label = select(2, getSwipeAnimationDelaySettingKey())
        showNumberInputDialog(
            touchmenu_instance,
            _("Animation frame delay"),
            current_value,
            getAutomaticSwipeAnimationDelayMs(),
            orientation_label,
            _([[
Enter the delay between animation frames, in milliseconds.

Lower values are faster but may cause more ghosting.
Higher values are slower but usually look cleaner.

Current orientation: %1
Current default: %2 ms]]),
            function(v)
                if not v or v < 1 then
                    saveConfiguredSwipeAnimationDelayMs(nil)
                else
                    saveConfiguredSwipeAnimationDelayMs(v)
                end
            end
        )
    end

    local function showSwipeAnimationStepsInputDialog(touchmenu_instance)
        local current_value = tostring(getConfiguredSwipeAnimationSteps() or getAutomaticSwipeAnimationSteps())
        local orientation_label = select(2, getSwipeAnimationStepsSettingKey())
        showNumberInputDialog(
            touchmenu_instance,
            _("Animation steps"),
            current_value,
            getAutomaticSwipeAnimationSteps(),
            orientation_label,
            _([[
Enter the number of wipe strips used to build the animation.

Fewer strips = faster, coarser wipe. More strips = slower, smoother wipe.
Portrait and landscape remember their own values. When unset, the default
for the current orientation is shown.

On the Kindle 4 (Pearl eink), 2-4 strips is a good balance.]]),
            function(v)
                if not v or v < 1 then
                    saveConfiguredSwipeAnimationSteps(nil)
                else
                    saveConfiguredSwipeAnimationSteps(v)
                end
            end
        )
    end

    local function buildSwipeAnimationSubItems()
        local legacy = isLegacyKindle()
        local ui_label     = legacy and _("UI refresh") or _("UI refresh (default, recommended)")
        local fast_label   = legacy and _("Fast refresh (default, recommended)") or _("Fast refresh (fastest, more ghosting)")

        local items = {
            -- Refresh mode chooser
            {
                text = _("Swipe animation refresh mode"),
                enabled_func = function()
                    return G_reader_settings:isTrue("swipe_animations")
                end,
                help_text = _([[
Choose the refresh type used for each strip of the software swipe animation.

• UI refresh: balanced quality and speed, suitable for most cases.
• Fast refresh: fastest, best for smoothness when some ghosting is acceptable.

Changes take effect immediately.]]),
                sub_item_table = {
                    {
                        text = ui_label,
                        checked_func = function()
                            return getSwipeAnimationRefreshMode() == "ui"
                        end,
                        callback = function(touchmenu_instance)
                            saveSwipeAnimationRefreshMode("ui")
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    },
                    {
                        text = fast_label,
                        checked_func = function()
                            return getSwipeAnimationRefreshMode() == "fast"
                        end,
                        callback = function(touchmenu_instance)
                            saveSwipeAnimationRefreshMode("fast")
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    },
                },
            },
            -- Delay setting
            {
                text_func = function()
                    local configured = getConfiguredSwipeAnimationDelayMs()
                    local orientation_label = select(2, getSwipeAnimationDelaySettingKey())
                    if configured then
                        return T(_("%1 animation frame delay: %2 ms"), orientation_label, configured)
                    end
                    return T(_("%1 animation frame delay: default %2 ms"), orientation_label, getAutomaticSwipeAnimationDelayMs())
                end,
                enabled_func = function()
                    return G_reader_settings:isTrue("swipe_animations")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showSwipeAnimationDelayInputDialog(touchmenu_instance)
                end,
                help_text = _([[
Adjust the pause between animation frames.

Enter a value in milliseconds. Portrait and landscape remember their own values.
When unset, the default for the current orientation is shown.]]),
            },
            -- Steps setting
            {
                text_func = function()
                    local configured = getConfiguredSwipeAnimationSteps()
                    local orientation_label = select(2, getSwipeAnimationStepsSettingKey())
                    if configured then
                        return T(_("%1 animation steps: %2"), orientation_label, configured)
                    end
                    return T(_("%1 animation steps: default %2"), orientation_label, getAutomaticSwipeAnimationSteps())
                end,
                enabled_func = function()
                    return G_reader_settings:isTrue("swipe_animations")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showSwipeAnimationStepsInputDialog(touchmenu_instance)
                end,
                help_text = _([[
Enter the number of wipe strips used to build the animation.

Fewer strips = faster, coarser wipe. More strips = slower, smoother wipe.
Portrait and landscape remember their own values. When unset, the default
for the current orientation is shown.

On the Kindle 4 (Pearl eink), 2-4 strips is a good balance.]]),
            },
            -- Animation engine chooser
            {
                text = _("Animation engine"),
                enabled_func = function()
                    return G_reader_settings:isTrue("swipe_animations")
                end,
                help_text = _([[
Choose the animation engine.

• Zero-copy (recommended): sends strip refreshes directly. Fastest, and the
  only safe choice on Kindle 4 (the blitbuffer slow path would otherwise stall).
• Buffered: restores the previous page and blits strips back. Only needed on
  framebuffer backends that do not paint straight to the panel (e.g. SDL/
  emulator). On Kindle 4 it is much slower and may stall under rotation.

Changes take effect on the next page turn.]]),
                sub_item_table = {
                    {
                        text = _("Zero-copy (recommended, fastest)"),
                        checked_func = function()
                            return getSwipeAnimationEngine() == "zerocopy"
                        end,
                        callback = function(touchmenu_instance)
                            saveSwipeAnimationEngine("zerocopy")
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    },
                    {
                        text = _("Buffered (compatible, slower)"),
                        checked_func = function()
                            return getSwipeAnimationEngine() == "buffer"
                        end,
                        callback = function(touchmenu_instance)
                            saveSwipeAnimationEngine("buffer")
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    },
                },
            },
        }

        -- einkfb fast refresh toggle — only meaningful on legacy Kindle
        -- (K2/K3/K4/DXG), where we install the fx_update_fast waveform.
        if legacy then
            table.insert(items, {
                text = _("Use einkfb fast refresh (fx_update_fast)"),
                enabled_func = function()
                    return G_reader_settings:isTrue("swipe_animations")
                end,
                checked_func = function()
                    return isEinkfbFastEnabled()
                end,
                callback = function(touchmenu_instance)
                    toggleEinkfbFast()
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
                help_text = _([[
Use the einkfb fx_update_fast waveform for the strip refreshes instead of the
default partial waveform.

On the Kindle 4 this is much faster (Pearl partial is ~400-500 ms per strip).
If your kernel rejects the fast waveform, KOReader automatically falls back to
partial and this toggle has no further effect.]]),
            })
        end

        return items
    end

    local function buildSettingsMenu()
        return {
            text = _("Swipe animation settings"),
            enabled_func = function()
                return G_reader_settings:isTrue("swipe_animations")
            end,
            help_text = _([[
Adjust the speed (frame delay), wipe granularity (steps), refresh mode (UI /
Fast), and engine of the software swipe animation.

The refresh mode and engine directly affect the quality, ghosting, and speed
of each strip update during the animation. On non-touch devices (e.g. Kindle
4) the entity page-turn keys drive the animation direction automatically.]]),
            sub_item_table = buildSwipeAnimationSubItems(),
        }
    end

    -- Inject the settings item into the "Page turn animations" submenu.
    -- We deliberately target page_turns (not taps_and_gestures) so the
    -- settings are reachable on NON-TOUCH devices such as the Kindle 4,
    -- where taps_and_gestures may be hidden. page_turns is shown whenever
    -- Device:canDoSwipeAnimation() is true — which we force above.
    local function injectSettingsMenu(menu_items)
        if type(menu_items) ~= "table" then
            return false
        end

        local pt = menu_items["page_turns"]
        if type(pt) ~= "table" then
            -- Fallback: top-level entry (rare on stock KOReader).
            local existing = menu_items["swipe_animation_settings"]
            if type(existing) == "table" and existing._swipe_animation_settings_patch_item then
                existing.sub_item_table = buildSwipeAnimationSubItems()
                return true
            end
            local item = buildSettingsMenu()
            item._swipe_animation_settings_patch_item = true
            menu_items["swipe_animation_settings"] = item
            return true
        end

        if type(pt.sub_item_table) ~= "table" then
            pt.sub_item_table = {}
        end

        for _, it in ipairs(pt.sub_item_table) do
            if it._swipe_animation_settings_patch_item then
                it.sub_item_table = buildSwipeAnimationSubItems()
                return true
            end
        end

        local item = buildSettingsMenu()
        item._swipe_animation_settings_patch_item = true
        table.insert(pt.sub_item_table, item)
        return true
    end

    local orig_setUpdateItemTable = ReaderMenu.setUpdateItemTable
    ReaderMenu.setUpdateItemTable = function(self, ...)
        injectSettingsMenu(self.menu_items)
        return orig_setUpdateItemTable(self, ...)
    end
end)

if not ok then
    require("logger").warn("[SwipeAnimationSettingsPatch] failed:", err)
end
