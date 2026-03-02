local addonName, addon = ...

-- Default Settings
local defaults = {
    maxWidth = 2560,
    maxHeight = 1440,
    restrictWidth = false,
    restrictHeight = false,
}

-- Initialize SavedVariables
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UI_SCALE_CHANGED")
frame:RegisterEvent("DISPLAY_SIZE_CHANGED")

local function InitializeSettings()
    if not UltrawideFixDB then
        UltrawideFixDB = {}
    end
    if not UltrawideFixDB.profiles then
        UltrawideFixDB.profiles = {}
    end
end

local function GetResolutionKey()
    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    return string.format("%dx%d", physicalWidth, physicalHeight)
end

local function GetCurrentProfile()
    local key = GetResolutionKey()
    if UltrawideFixDB.profiles and UltrawideFixDB.profiles[key] then
        local profile = UltrawideFixDB.profiles[key]
        local merged = {}
        for k, v in pairs(defaults) do
            if profile[k] ~= nil then
                merged[k] = profile[k]
            else
                merged[k] = v
            end
        end
        return merged
    end
    return defaults
end

local function SetCurrentProfileValue(settingKey, value)
    local key = GetResolutionKey()
    if not UltrawideFixDB.profiles then
        UltrawideFixDB.profiles = {}
    end
    if type(UltrawideFixDB.profiles[key]) ~= "table" then
        UltrawideFixDB.profiles[key] = {}
    end
    UltrawideFixDB.profiles[key][settingKey] = value
end

local isResizing = false

-- Store the original GetCursorPosition so we can wrap it
local OriginalGetCursorPosition = GetCursorPosition

-- Offset tracking: how much UIParent's BOTTOMLEFT is shifted from screen BOTTOMLEFT
-- These are in logical (scaled) coordinates
local uiParentOffsetX = 0
local uiParentOffsetY = 0

-- Replace GetCursorPosition globally so that all Blizzard code (dropdown menus,
-- context menus, etc.) that converts cursor coords to UIParent-space using
--   cursorX / UIParent:GetEffectiveScale()
-- gets the correct result. Without this, menus appear shifted because UIParent
-- is centered and smaller than the full screen.
GetCursorPosition = function()
    local x, y = OriginalGetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    -- Subtract the UIParent offset (converted back to unscaled screen coords)
    return x - (uiParentOffsetX * scale), y - (uiParentOffsetY * scale)
end

local function UpdateUIParent()
    if isResizing then return end
    isResizing = true

    local physicalWidth, physicalHeight = GetPhysicalScreenSize()

    -- Use logical screen size for setting UIParent dimensions
    local logicalWidth = GetScreenWidth()
    local logicalHeight = GetScreenHeight()

    -- Reset UIParent to default before applying restrictions
    UIParent:ClearAllPoints()
    UIParent:SetPoint("CENTER")
    -- In WoW 10.0+ UIParent is often bounded by logical screen size
    UIParent:SetSize(logicalWidth, logicalHeight)

    local profile = GetCurrentProfile()

    local targetLogicalWidth = logicalWidth
    local targetLogicalHeight = logicalHeight

    if profile.restrictWidth then
        -- Scale user's pixel max to logical max
        local maxLogicalWidth = logicalWidth * (profile.maxWidth / physicalWidth)
        targetLogicalWidth = math.min(logicalWidth, maxLogicalWidth)
    end
    if profile.restrictHeight then
        local maxLogicalHeight = logicalHeight * (profile.maxHeight / physicalHeight)
        targetLogicalHeight = math.min(logicalHeight, maxLogicalHeight)
    end

    UIParent:SetSize(targetLogicalWidth, targetLogicalHeight)

    -- Update offsets: UIParent is centered, so the BOTTOMLEFT offset is
    -- half the difference between the full screen and the restricted size
    uiParentOffsetX = (logicalWidth - targetLogicalWidth) / 2
    uiParentOffsetY = (logicalHeight - targetLogicalHeight) / 2

    isResizing = false

    -- Refresh EditMode magnetism manager's cached UIParent points whenever
    -- we resize UIParent, so snap guide lines stay aligned.
    if EditModeMagnetismManager and EditModeMagnetismManager.UpdateUIParentPoints then
        EditModeMagnetismManager:UpdateUIParentPoints()
    end
end

-- ---------------------------------------------------------------------------
-- EditMode Compatibility Fixes
-- ---------------------------------------------------------------------------
-- When UIParent is smaller than the screen and centered, several EditMode
-- functions break because they assume UIParent's origin matches the screen
-- origin. We hook the specific functions that do incorrect coordinate math.

local function InstallEditModeHooks()
    if not EditModeSystemMixin then return end

    -- Fix 1: BreakFrameSnap (nudging with arrow keys, and save-time re-anchoring)
    --
    -- The original computes UIParent-relative offsets from screen-space
    -- positions (GetLeft/GetTop/GetRight), assuming UIParent's edges align
    -- with the screen edges. When UIParent is centered and smaller, the
    -- offsets are wrong by the UIParent offset amount.
    --
    -- We replace the method to use UIParent:GetLeft/GetTop/GetRight as
    -- reference points instead of implicitly assuming 0/GetHeight/GetWidth.
    local OriginalBreakFrameSnap = EditModeSystemMixin.BreakFrameSnap
    EditModeSystemMixin.BreakFrameSnap = function(self, deltaX, deltaY)
        if uiParentOffsetX == 0 and uiParentOffsetY == 0 then
            return OriginalBreakFrameSnap(self, deltaX, deltaY)
        end

        local top = self:GetTop()
        if top then
            local scale = self:GetScale()

            -- Original: offsetY = -((UIParent:GetHeight() - top * scale) / scale)
            -- This assumes UIParent top = UIParent:GetHeight() in screen coords.
            -- Fix: use UIParent:GetTop() (the actual screen-space top edge).
            local uiTop = UIParent:GetTop()
            local offsetY = -((uiTop - top * scale) / scale)

            local offsetX, anchorPoint
            if self.alwaysUseTopRightAnchor then
                -- Original: offsetX = -((UIParent:GetWidth() - self:GetRight() * scale) / scale)
                -- Fix: use UIParent:GetRight() instead of UIParent:GetWidth()
                local uiRight = UIParent:GetRight()
                offsetX = -((uiRight - self:GetRight() * scale) / scale)
                anchorPoint = "TOPRIGHT"
            else
                -- Original: offsetX = self:GetLeft()
                -- This assumes UIParent left edge is at screen position 0.
                -- Fix: convert self:GetLeft() to UIParent's coordinate space
                -- (multiply by scale), subtract UIParent's left edge position
                -- (also in UIParent's coordinate space), then convert back to
                -- self's coordinate space (divide by scale) for SetPoint.
                offsetX = (self:GetLeft() * scale - UIParent:GetLeft()) / scale
                anchorPoint = "TOPLEFT"
            end

            if deltaX then
                offsetX = offsetX + deltaX
            end
            if deltaY then
                offsetY = offsetY + deltaY
            end

            self:ClearAllPoints()
            self:SetPoint(anchorPoint, UIParent, anchorPoint, offsetX, offsetY)
            self:OnSystemPositionChange()
        end
    end

    -- Fix 2: FindClosestGridLine grid-snap offsets
    --
    -- When snapping to a grid line, FindClosestGridLine returns an offset
    -- that eventually becomes a SetPoint offset relative to UIParent.
    -- For TOP and RIGHT snap points, the offset is relative to UIParent's
    -- top/right edge (gridPos - uiParentTop/Right), which works correctly.
    -- For CENTER, it's relative to UIParent's center, also correct.
    -- But for LEFT and BOTTOM snap points, the offset is the raw screen-
    -- space grid line position. This is used as a SetPoint offset from
    -- UIParent's LEFT/BOTTOM anchor, which only works when UIParent starts
    -- at screen origin (0,0). When UIParent is centered and offset, the
    -- raw screen position is too large, placing the frame too far right/up.
    --
    -- Fix: subtract UIParent's left/bottom screen position from LEFT/BOTTOM
    -- offsets to convert them to UIParent-relative values.
    if EditModeMagnetismManager then
        local OriginalFindClosestGridLine = EditModeMagnetismManager.FindClosestGridLine
        EditModeMagnetismManager.FindClosestGridLine = function(self, systemFrame, verticalLines)
            local closestDistance, closestPoint, closestRelativePoint, closestOffset =
                OriginalFindClosestGridLine(self, systemFrame, verticalLines)

            if uiParentOffsetX == 0 and uiParentOffsetY == 0 then
                return closestDistance, closestPoint, closestRelativePoint, closestOffset
            end

            -- Only adjust non-zero offsets (0 = edge/center snap, not grid)
            if closestOffset and closestOffset ~= 0 then
                -- LEFT and BOTTOM offsets are raw screen positions in the
                -- original code. TOP/RIGHT/CENTER offsets are already relative
                -- to UIParent edges/center. Convert LEFT/BOTTOM to UIParent-
                -- relative by subtracting UIParent's screen-space origin.
                if closestPoint == "LEFT" then
                    closestOffset = closestOffset - self.uiParentLeft
                elseif closestPoint == "BOTTOM" then
                    closestOffset = closestOffset - self.uiParentBottom
                end
            end

            return closestDistance, closestPoint, closestRelativePoint, closestOffset
        end
    end

    -- Fix 3: Snap preview guide lines
    --
    -- MagnetismPreviewLineMixin:Setup positions lines using offsets from
    -- UIParent's center anchor. It uses cached screen-space uiParentCenterX/Y,
    -- but SetStartPoint/SetEndPoint are relative to UIParent. When UIParent
    -- doesn't fill the screen, lines are misaligned.
    --
    -- For UIParent lines we use UIParent-local center (width/2, height/2).
    -- For non-UIParent frame lines, the original screen-space math is correct.
    if MagnetismPreviewLineMixin then
        local OriginalSetup = MagnetismPreviewLineMixin.Setup
        MagnetismPreviewLineMixin.Setup = function(self, magneticFrameInfo, lineAnchor)
            if uiParentOffsetX == 0 and uiParentOffsetY == 0 then
                return OriginalSetup(self, magneticFrameInfo, lineAnchor)
            end

            local mgr = EditModeMagnetismManager
            local relativeTo = magneticFrameInfo.frame
            local isLineAnchoringHorizontally = (lineAnchor == "Top" or lineAnchor == "Bottom"
                                                 or lineAnchor == "CenterHorizontal")

            local startPoint, endPoint
            if isLineAnchoringHorizontally then
                startPoint, endPoint = "LEFT", "RIGHT"
            else
                startPoint, endPoint = "TOP", "BOTTOM"
            end

            local offsetX, offsetY = 0, 0

            if relativeTo == UIParent then
                -- After Fix 2, all grid line offsets from FindClosestGridLine
                -- are now UIParent-relative (LEFT/BOTTOM offsets were converted
                -- from raw screen-space). This means we can use the original
                -- formula pattern but with UIParent-local center (width/2,
                -- height/2) instead of screen-space center.
                --
                -- The pattern for each anchor:
                --   LEFT:   line at UIParent left  + offset → from center: offset - width/2
                --   RIGHT:  line at UIParent right + offset → from center: offset + width/2
                --   BOTTOM: line at UIParent bottom + offset → from center: offset - height/2
                --   TOP:    line at UIParent top    + offset → from center: offset + height/2
                --   CENTER: offset is already relative to center
                local localCenterX = mgr.uiParentWidth / 2
                local localCenterY = mgr.uiParentHeight / 2

                if lineAnchor == "CenterHorizontal" then
                    offsetY = magneticFrameInfo.offset
                elseif lineAnchor == "CenterVertical" then
                    offsetX = magneticFrameInfo.offset
                elseif lineAnchor == "Top" or lineAnchor == "Bottom" then
                    if lineAnchor == "Top" then
                        offsetY = magneticFrameInfo.offset + localCenterY
                    else
                        offsetY = magneticFrameInfo.offset - localCenterY
                    end
                elseif lineAnchor == "Right" or lineAnchor == "Left" then
                    if lineAnchor == "Right" then
                        offsetX = magneticFrameInfo.offset + localCenterX
                    else
                        offsetX = magneticFrameInfo.offset - localCenterX
                    end
                end
            else
                -- For non-UIParent frames, the original screen-space math is
                -- correct: (screenPos - screenCenterOfUIParent) gives the
                -- right offset from UIParent's center for SetStartPoint.
                return OriginalSetup(self, magneticFrameInfo, lineAnchor)
            end

            self:SetStartPoint(startPoint, UIParent, offsetX, offsetY)
            self:SetEndPoint(endPoint, UIParent, offsetX, offsetY)
            local linePixelWidth = 1.5
            local lineThickness = PixelUtil.GetNearestPixelSize(
                linePixelWidth, self:GetEffectiveScale(), linePixelWidth)
            self:SetThickness(lineThickness)
            self:Show()
        end
    end
end

-- Live Preview Logic
local previewFrame = nil
local previewTimer = nil

local function ShowPreview()
    if not previewFrame then
        previewFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        previewFrame:SetFrameStrata("TOOLTIP")
        previewFrame:SetPoint("CENTER")
        previewFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        previewFrame:SetBackdropColor(0, 1, 0, 0.2) -- Transparent Green interior
        previewFrame:SetBackdropBorderColor(0, 1, 0, 1) -- Solid Green border
    end

    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    local logicalWidth = GetScreenWidth()
    local logicalHeight = GetScreenHeight()

    local targetLogicalWidth = logicalWidth
    local targetLogicalHeight = logicalHeight

    local profile = GetCurrentProfile()

    if profile.restrictWidth then
        local maxLogicalWidth = logicalWidth * (profile.maxWidth / physicalWidth)
        targetLogicalWidth = math.min(logicalWidth, maxLogicalWidth)
    end
    if profile.restrictHeight then
        local maxLogicalHeight = logicalHeight * (profile.maxHeight / physicalHeight)
        targetLogicalHeight = math.min(logicalHeight, maxLogicalHeight)
    end

    previewFrame:SetSize(targetLogicalWidth, targetLogicalHeight)
    previewFrame:Show()

    if previewTimer then
        previewTimer:Cancel()
    end
    previewTimer = C_Timer.NewTimer(3, function()
        previewFrame:Hide()
    end)
end

function addon.BuildSettingsMenu()
    local category_name = "Ultrawide Fix"
    local category = Settings.RegisterVerticalLayoutCategory(category_name)
    Settings.RegisterAddOnCategory(category)
    local restrictWidthSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_RestrictWidth",
        "boolean",
        "Restrict Width",
        false,
        function() return GetCurrentProfile().restrictWidth end,
        function(value)
            SetCurrentProfileValue("restrictWidth", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    Settings.CreateCheckbox(category, restrictWidthSetting, "Enable restricting the maximum width of the UI.")

    local maxWidthSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_MaxWidth",
        "number",
        "Max Width (pixels)",
        2560,
        function() 
            local pw = GetPhysicalScreenSize()
            local val = GetCurrentProfile().maxWidth
            return math.floor(math.min(pw, val) + 0.5)
        end,
        function(value)
            local pw = GetPhysicalScreenSize()
            value = math.floor(math.min(pw, value) + 0.5)
            SetCurrentProfileValue("maxWidth", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    local widthOptions = Settings.CreateSliderOptions(800, math.max(800, physicalWidth), 10)
    if MinimalSliderWithSteppersMixin then
        widthOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(category, maxWidthSetting, widthOptions, "Maximum allowed width in pixels.")

    local restrictHeightSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_RestrictHeight",
        "boolean",
        "Restrict Height",
        false,
        function() return GetCurrentProfile().restrictHeight end,
        function(value)
            SetCurrentProfileValue("restrictHeight", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    Settings.CreateCheckbox(category, restrictHeightSetting, "Enable restricting the maximum height of the UI.")

    local maxHeightSetting = Settings.RegisterProxySetting(
        category,
        "UltrawideFix_MaxHeight",
        "number",
        "Max Height (pixels)",
        1440,
        function() 
            local pw, ph = GetPhysicalScreenSize()
            local val = GetCurrentProfile().maxHeight
            return math.floor(math.min(ph, val) + 0.5)
        end,
        function(value)
            local pw, ph = GetPhysicalScreenSize()
            value = math.floor(math.min(ph, value) + 0.5)
            SetCurrentProfileValue("maxHeight", value)
            UpdateUIParent()
            ShowPreview()
        end
    )
    local heightOptions = Settings.CreateSliderOptions(600, math.max(600, physicalHeight), 10)
    if MinimalSliderWithSteppersMixin then
        heightOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(category, maxHeightSetting, heightOptions, "Maximum allowed height in pixels.")

    addon.UpdateSettingsUI = function()
        -- The modern DF API handles automatic binding to ProxySettings getters.
    end
end

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        InitializeSettings()
        InstallEditModeHooks()
        if addon.BuildSettingsMenu then
            addon.BuildSettingsMenu()
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" or event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
        UpdateUIParent()
        if addon.UpdateSettingsUI then
            addon.UpdateSettingsUI()
        end
    end
end)

addon.UpdateUIParent = UpdateUIParent
