--[[
    2-swipe-animation-core.lua
    Swipe_Animation —— Kindle 4（非触摸 / 传统 einkfb）适配与性能优化版

    与上游原版的主要差异
    --------------------------------------------------------------------
    1. 不再需要替换 frontend/ui/uimanager.lua。
       原版把 uimanager.lua 整份替换，并在 _repaint() 里插入动画调用；
       这在 Kindle 4 这类需要长期停留在特定 KOReader 版本的老设备上非常
       危险（版本一错就闪退）。本版改为运行期挂钩 Screen 的各个刷新实现
       方法（*Imp 层），这一层是所有公开刷新方法的最终落点，与 KOReader
       版本无关，也无需任何核心文件改动。

    2. 新增「零拷贝」动画引擎（默认）。
       电子墨水屏的像素在未刷新前会一直保持上一页画面，framebuffer 里的
       新页面只有被 refresh 到的区域才会真正显示。因此只要按条带顺序发起
       局部刷新，就能得到与原版完全相同的擦除效果，而 **不需要**：
         - Screen.bb:copy() × 2（Kindle 4 上每次翻页约 1 MB 的分配/释放）
         - 任何 blitFrom 条带拷贝
       Kindle 4 的 Device.canUseCBB = false，blitbuffer 走纯 Lua 路径；
       且屏幕旋转后 blitTo8 会退化到逐像素的 blitDefault（并且该函数上游
       存在 for y = dest_y, dest_y+width-1 的行数笔误），在 800 MHz 的
       i.MX50 上等同于卡死。零拷贝引擎彻底绕开了这条路径，也天然支持旋转。

    3. 删除对 KOReader 整屏刷新计数（FULL_REFRESH_COUNT）、章节/图片强制
       全刷的重复实现（原版约 120 行）。本版在刷新执行的最后一环拦截，
       上游已经把 partial 提升成 full/flashui 的那一帧会自动跳过动画，
       逻辑更短、更准，也省掉每次翻页的 ReaderToc / img_coverage 计算。

    4. 传统 Kindle（K2/K3/K4/DXG）专用：为 ffi/framebuffer_einkfb 补上
       refreshFastImp，使用 einkfb 的 fx_update_fast 波形。上游 einkfb
       只实现了 refreshPartialImp / refreshFullImp，refreshFast 会退化成
       partial（Pearl 屏约 400~500 ms），8 条带动画要 3 秒以上。
       ioctl 失败会自动永久回退，不会影响正常使用。

    5. 非触摸设备（Kindle 4）默认参数：竖屏 3 段、横屏 2 段、帧延迟 0 ms。
       einkfb 的更新 ioctl 是异步入队、由驱动串行执行的，条带之间无需
       sleep 也能看到顺序擦除，额外 sleep 只会平白拉长翻页时间。

方向来源（与输入方式无关）：
- 触摸滑动：ReaderRolling 发出 PageChangeAnimation → ReaderView →
  Screen:setSwipeDirection。
- 实体翻页键（Kindle 4 主路径）：ReaderView:onPageUpdate 在页码真正改变时
  直接置位 Screen.swipe_animations / setSwipeDirection（见第 6 节）。
两条路径最终都由第 5 节的 *Imp 拦截层接管本次翻页刷新，因此 Kindle 4 的
实体翻页键同样能得到正确的动画方向。
]]

local ok, err = pcall(function()

local Device = require("device")
local Screen = Device.screen
if not Screen then return end

local UIManager = require("ui/uimanager")
local logger    = require("logger")
local ffi       = require("ffi")

if UIManager._swipe_anim_core_applied then return end
UIManager._swipe_anim_core_applied = true

----------------------------------------------------------------------
-- 0. 设备画像与默认参数
----------------------------------------------------------------------

-- 使用 ffi/framebuffer_einkfb 的老 Kindle（Pearl 屏 + eink_fb 驱动）
local LEGACY_KINDLE_MODELS = {
    Kindle2   = true,
    Kindle3   = true,
    Kindle4   = true,
    KindleDXG = true,
}
local is_legacy_kindle = Device:isKindle() and LEGACY_KINDLE_MODELS[Device.model] == true
local is_non_touch     = not Device:isTouchDevice()

local PROFILE
if is_legacy_kindle then
    PROFILE = {
        steps        = { portrait = 3, landscape = 2 },
        delay_ms     = { portrait = 0, landscape = 0 },
        refresh_mode = "fast",   -- fx_update_fast
        wait_for_last = false,   -- einkfb 无 wait ioctl
        align        = 8,        -- 老驱动对刷新矩形做 8px 对齐更保险
    }
else
    PROFILE = {
        steps        = { portrait = 8,  landscape = 6 },
        delay_ms     = { portrait = 20, landscape = 10 },
        refresh_mode = "ui",
        wait_for_last = true,    -- mxcfb 可以精确等待上一帧完成
        align        = 1,
    }
end

-- 单一数据源，供 2-swipe-animation-settings.lua 读取
UIManager.swipe_animation_defaults = {
    steps            = PROFILE.steps,
    delay_ms         = PROFILE.delay_ms,
    refresh_mode     = PROFILE.refresh_mode,
    is_legacy_kindle = is_legacy_kindle,
    is_non_touch     = is_non_touch,
}

----------------------------------------------------------------------
-- 1. framebuffer 状态挂钩（不改 ffi/framebuffer.lua）
----------------------------------------------------------------------

if not Screen._swipe_anim_fb_hooked then
    Screen._swipe_anim_fb_hooked = true

    -- 上游基类只是空实现，这里把状态落到实例上
    local orig_setSwipeAnimations = Screen.setSwipeAnimations
    function Screen:setSwipeAnimations(enabled)
        if orig_setSwipeAnimations then orig_setSwipeAnimations(self, enabled) end
        self.swipe_animations = enabled
    end

    -- MTK 设备上原方法是带旋转处理的硬件 ioctl，保留调用
    local orig_setSwipeDirection = Screen.setSwipeDirection
    function Screen:setSwipeDirection(direction)
        if orig_setSwipeDirection then orig_setSwipeDirection(self, direction) end
        self.swipe_forward = direction
    end

    -- 缓冲区兼容引擎才需要的「上一页」快照；零拷贝引擎下完全不执行
    local orig_beforePaint = Screen.beforePaint
    function Screen:beforePaint()
        if not self._swipe_painting then
            self._swipe_painting = true
            if self.swipe_animations and self._swipe_need_snapshot then
                if self.saved_bb then self.saved_bb:free() end
                self.saved_bb = self.bb:copy()
            end
        end
        if orig_beforePaint then return orig_beforePaint(self) end
    end

    -- 兜底：任何一次绘制结束都清掉标志，避免它泄漏到下一次无关重绘
    local orig_afterPaint = Screen.afterPaint
    function Screen:afterPaint()
        self._swipe_painting = false
        self.swipe_animations = false
        if self.saved_bb then
            self.saved_bb:free()
            self.saved_bb = nil
        end
        if orig_afterPaint then return orig_afterPaint(self) end
    end
end

----------------------------------------------------------------------
-- 2. 传统 Kindle：为 einkfb 补 refreshFastImp（fx_update_fast）
----------------------------------------------------------------------

local function installEinkfbFastRefresh()
    if not is_legacy_kindle then return end
    if Screen._swipe_anim_fast_installed then return end
    if not Screen.fd then return end                      -- 非 linuxfb 后端（模拟器）
    if not pcall(require, "ffi/posix_h") then return end
    if not pcall(require, "ffi/einkfb_h") then return end

    local C = ffi.C
    if not pcall(function() return C.FBIO_EINK_UPDATE_DISPLAY_AREA end) then return end

    Screen._swipe_anim_fast_installed = true

    local refarea = ffi.new("struct update_area_t[1]")    -- 复用，避免每帧分配
    local broken  = false

    function Screen:refreshFastImp(x, y, w, h, d)
        if broken or not G_reader_settings:nilOrTrue("swipe_animation_einkfb_fast") then
            return self:refreshPartialImp(x, y, w, h, d)
        end
        local ok, res = pcall(function()
            local px, py, pw, ph = self.bb:getBoundedRect(x, y, w, h)
            px, py, pw, ph = self.bb:getPhysicalRect(px, py, pw, ph)
            refarea[0].x1 = px
            refarea[0].y1 = py
            refarea[0].x2 = px + pw
            refarea[0].y2 = py + ph
            refarea[0].buffer = nil
            refarea[0].which_fx = C.fx_update_fast
            return C.ioctl(self.fd, C.FBIO_EINK_UPDATE_DISPLAY_AREA, refarea)
        end)
        if not ok or res ~= 0 then
            broken = true
            logger.warn("[SwipeAnimation] einkfb fx_update_fast rejected, falling back to partial")
            return self:refreshPartialImp(x, y, w, h, d)
        end
    end
end
installEinkfbFastRefresh()

----------------------------------------------------------------------
-- 3. 工具
----------------------------------------------------------------------

local usleep
do
    local ok_util, util = pcall(require, "ffi/util")
    if ok_util and util and util.usleep then
        usleep = util.usleep
    else
        local ok_c = pcall(function() return ffi.C.usleep end)
        usleep = ok_c and ffi.C.usleep or nil
    end
end

local function isLandscape()
    return Screen:getWidth() > Screen:getHeight()
end

local function readNumber(key)
    local v = tonumber(G_reader_settings:readSetting(key))
    if v and v >= 0 then return v end
    return nil
end

local function getSteps()
    if isLandscape() then
        return readNumber("swipe_animation_steps_horizontal") or PROFILE.steps.landscape
    end
    return readNumber("swipe_animation_steps_vertical") or PROFILE.steps.portrait
end

local function getDelayUs()
    local ms
    if isLandscape() then
        ms = readNumber("swipe_animation_delay_ms_horizontal") or PROFILE.delay_ms.landscape
    else
        ms = readNumber("swipe_animation_delay_ms_vertical") or PROFILE.delay_ms.portrait
    end
    return ms * 1000
end

-- 用于条带刷新的方法：ui / fast
local function getStripRefresh()
    local mode = G_reader_settings:readSetting("swipe_animation_refresh_mode") or PROFILE.refresh_mode
    if mode == "fast" and type(Screen.refreshFast) == "function" then
        return Screen.refreshFast
    end
    return Screen.refreshUI or Screen.refreshPartial
end

local function getEngine()
    -- zerocopy（默认，推荐）/ buffer（兼容：framebuffer 不直连面板的后端）
    local e = G_reader_settings:readSetting("swipe_animation_engine")
    if e == "buffer" then return "buffer" end
    return "zerocopy"
end

----------------------------------------------------------------------
-- 4. 动画本体
----------------------------------------------------------------------

-- 生成条带序列：forward 时从右向左揭开新页，backward 时从左向右
local function buildStrips(x, w, steps, align, forward)
    local strips, prev = {}, 0
    for i = 1, steps do
        local dx = math.floor(w * i / steps)
        if align > 1 and i < steps then
            dx = dx - (dx % align)
        end
        if dx > prev then
            local sw = dx - prev
            local sx = forward and (x + w - dx) or (x + prev)
            strips[#strips + 1] = { x = sx, w = sw }
            prev = dx
        end
    end
    if prev < w then
        local sw = w - prev
        local sx = forward and x or (x + prev)
        strips[#strips + 1] = { x = sx, w = sw }
    end
    return strips
end

-- 零拷贝引擎：只发刷新，不动任何缓冲区
local function animateZeroCopy(strips, y, h, dither, refresh_fn, delay_us, wait)
    local n = #strips
    for i = 1, n do
        local s = strips[i]
        refresh_fn(Screen, s.x, y, s.w, h, dither)
        if wait then Screen:refreshWaitForLast() end
        if delay_us > 0 and i < n and usleep then usleep(delay_us) end
    end
end

-- 缓冲区兼容引擎：还原上一页 → 逐条贴回新页（用于 framebuffer 非直连面板的后端）
local function animateBuffered(strips, x, y, w, h, dither, refresh_fn, delay_us, wait)
    local saved_bb = Screen.saved_bb
    Screen.saved_bb = nil
    if not saved_bb then return false end

    local new_bb = Screen.bb:copy()
    if Screen.bb.blitFullFrom then
        Screen.bb:blitFullFrom(saved_bb)
    else
        Screen.bb:blitFrom(saved_bb, 0, 0, 0, 0, w, h)
    end

    local n = #strips
    for i = 1, n do
        local s = strips[i]
        Screen.bb:blitFrom(new_bb, s.x, y, s.x, y, s.w, h)
        refresh_fn(Screen, s.x, y, s.w, h, dither)
        if wait then Screen:refreshWaitForLast() end
        if delay_us > 0 and i < n and usleep then usleep(delay_us) end
    end

    new_bb:free()
    saved_bb:free()
    return true
end

local function canUseBufferedEngine()
    -- 旋转状态下且没有 C blitter 时，blitFrom 会掉进逐像素的 Lua 慢路径，
    -- 在 Kindle 4 上等于卡死，直接放弃动画。
    local bb = Screen.bb
    if not bb then return false end
    if bb.getRotation and bb:getRotation() ~= 0 then
        if not (bb.canUseCbb and bb:canUseCbb()) then
            return false
        end
    end
    return true
end

local function runAnimation(x, y, w, h, dither)
    local engine = getEngine()
    local steps  = getSteps()
    if steps < 2 then return false end
    -- 条带不能比对齐粒度还窄
    local max_steps = math.max(1, math.floor(w / math.max(PROFILE.align, 8)))
    if steps > max_steps then steps = max_steps end
    if steps < 2 then return false end

    local forward = Screen.swipe_forward
    if forward == nil then forward = true end

    local strips     = buildStrips(x, w, steps, PROFILE.align, forward)
    local refresh_fn = getStripRefresh()
    local delay_us   = getDelayUs()
    local wait       = PROFILE.wait_for_last and Screen.refreshWaitForLast ~= nil

    if engine == "buffer" then
        if not canUseBufferedEngine() then return false end
        return animateBuffered(strips, x, y, w, h, dither, refresh_fn, delay_us, wait)
    end

    animateZeroCopy(strips, y, h, dither, refresh_fn, delay_us, wait)
    return true
end

----------------------------------------------------------------------
-- 5. 拦截刷新执行（不改核心文件，且版本无关）
----------------------------------------------------------------------

-- 只有这些刷新模式值得做动画；full / flashui / flashpartial 说明本帧
-- 上游决定要闪一次（整屏清残影 / 章节边界 / 图片页），直接放行。
local ANIMATABLE = {
    partial       = true,
    ui            = true,
    fast          = true,
    a2            = true,
    ["[ui]"]      = true,
    ["[partial]"] = true,
}

-- 区域参数为空（无区域的全屏刷新）一律视为整屏，避免漏掉动画刷新。
local function isFullScreenRegion(x, y, w, h)
    if x == nil or y == nil or w == nil or h == nil then
        return true
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    return w >= sw - 2 and h >= sh - 2 and x <= 2 and y <= 2
end

-- 为什么在这一层拦截，而不是去挂钩 UIManager._repaint 里的 refresh_methods
-- 表：refresh_methods 在不同 KOReader 版本里可能是 _repaint 的 upvalue、也
-- 可能是模块级局部变量，定位方式不稳定（debug.getupvalue 扫描会失败）。而
-- 所有公开刷新方法（Screen:refreshFull / refreshPartial / refreshFast /
-- refreshUI / refreshA2 ...）最终都会落到对应的 *Imp 实现，所以在这里拦截
-- 是版本无关的，并且一定能命中翻页刷新。
local IMP_MODE = {
    refreshPartialImp        = "partial",
    refreshUIImp             = "ui",
    refreshFastImp           = "fast",
    refreshA2Imp             = "a2",
    refreshNoMergeUIImp      = "[ui]",
    refreshNoMergePartialImp = "[partial]",
    refreshFullImp           = "full",
    refreshFlashUIImp        = "flashui",
    refreshFlashPartialImp   = "flashpartial",
}

-- 重入守卫：动画内部的条带刷新会再次进入被包装的 *Imp，
-- 此时 in_animation 为 true，直接走原始实现，避免递归触发动画。
local in_animation = false

local function wrapRefreshImp(name, mode)
    local orig = Screen[name]
    if type(orig) ~= "function" then
        return
    end
    Screen[name] = function(self, x, y, w, h, dither)
        -- 1) 重入中，或动画标志未置位：直接走原始实现
        if in_animation or not self.swipe_animations then
            return orig(self, x, y, w, h, dither)
        end
        -- 2) 非动画候选（全屏闪 / 局部刷新）：保留标志，留给本轮后续
        --    可能出现的整屏动画刷新，避免被先到的局部刷新「吃掉」导致不动画。
        if not ANIMATABLE[mode] or not isFullScreenRegion(x, y, w, h) then
            return orig(self, x, y, w, h, dither)
        end
        -- 3) 命中整屏动画刷新：消费标志并播放擦除动画
        self.swipe_animations = false
        in_animation = true
        local ok, e = pcall(runAnimation, x, y, w, h, dither)
        in_animation = false

        if not ok then
            logger.warn("[SwipeAnimation] animation failed:", e)
        elseif e == false then
            -- 条件不满足（步数过小 / 旋转慢路径）：走普通刷新
        else
            -- 动画成功：条带刷新已逐步揭开新页。Kindle 4 的 fx_update_fast
            -- 条带画质偏低（文字发虚 / 锯齿），因此在动画成功后补一次较高
            -- 画质的整屏刷新把文字定影干净。用 public refreshPartial：此时
            -- in_animation 已复位、标志已消费，不会二次触发动画；非传统 Kindle
            -- 设备则沿用原始 *Imp（其刷新模式本身已足够清晰，无需额外刷新）。
            local settle = orig
            if is_legacy_kindle then
                settle = Screen.refreshPartial or Screen.refreshUI or orig
            end
            pcall(settle, self, x, y, w, h, dither)
            return
        end
        return orig(self, x, y, w, h, dither)
    end
end

for name, mode in pairs(IMP_MODE) do
    wrapRefreshImp(name, mode)
end

-- 缓冲区兼容引擎需要 beforePaint 抓快照；启动时按当前设置决定
Screen._swipe_need_snapshot = (getEngine() == "buffer")
UIManager.swipe_animation_setNeedSnapshot = function(need)
    Screen._swipe_need_snapshot = need and true or false
end

----------------------------------------------------------------------
-- 6. 让实体翻页键（所有非触摸翻页）也能触发动画
--    KOReader 仅在触摸滑动时发出 PageChangeAnimation 事件；实体键翻页
--    （ReaderRolling / ReaderPaging 的 onGotoViewRel）只发 PageUpdate，
--    从不触发动画标志。这里在 PageUpdate 里直接置位 Screen.swipe_animations，
--    使上面的 *Imp 拦截层能接管本次翻页刷新。方向由页码增减推断，并尊重
--    inverse_reading_order。仅在页码真正改变时触发，避免重绘误触发；
--    书籍初次打开时 self.state.page 为 nil，自然跳过，不会在开书时乱动画。
----------------------------------------------------------------------
local function installPageTurnTrigger()
    local ok_rv, ReaderView = pcall(require, "apps/reader/modules/readerview")
    if not ok_rv or not ReaderView then return end
    if ReaderView._swipe_anim_pageturn_hooked then return end
    ReaderView._swipe_anim_pageturn_hooked = true

    local orig_onPageUpdate = ReaderView.onPageUpdate
    ReaderView.onPageUpdate = function(self, new_page_no)
        local old_page = self.state and self.state.page
        local res = orig_onPageUpdate(self, new_page_no)
        if old_page and new_page_no ~= old_page
           and Device:canDoSwipeAnimation()
           and G_reader_settings:isTrue("swipe_animations") then
            local forward = new_page_no > old_page
            if self.inverse_reading_order then forward = not forward end
            Screen:setSwipeAnimations(true)
            Screen:setSwipeDirection(forward)
        end
        return res
    end
end
installPageTurnTrigger()

logger.info(string.format(
    "[SwipeAnimation] core ready (model=%s, legacy_einkfb=%s, non_touch=%s, engine=%s, steps=%d/%d, delay=%d/%d ms, mode=%s)",
    tostring(Device.model), tostring(is_legacy_kindle), tostring(is_non_touch),
    getEngine(), PROFILE.steps.portrait, PROFILE.steps.landscape,
    PROFILE.delay_ms.portrait, PROFILE.delay_ms.landscape, PROFILE.refresh_mode))

end)

if not ok then
    require("logger").warn("[SwipeAnimationCorePatch] failed:", err)
end
