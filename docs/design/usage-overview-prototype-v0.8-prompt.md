# 原型生成说明

方式：内置 image_gen 编辑 · 数据：虚构演示值 · 用途：PRD v0.8 评审。

参考：上一版原型、用户提供的对比条与每日用量标题截图、当前应用截图。

## 提示词

Use case: ui-mockup edit.
Edit reference image 1, the existing CodexUsage two-column prototype, to make the following precise product revisions. Preserve its native AppKit typography, warm orange palette, material, shadows, native controls, full left panel / focused right detail composition, and existing demo data. References 2 and 3 are the user's exact comparison strip and daily-section icon style. Reference 4 is the existing app screenshot for footer version and unchanged reset-card/Tibo layout.

Canvas: a complete, uncropped, crisp two-column Chinese prototype artboard, approximately 1920x2160 or a similarly tall high-resolution canvas. Left quiet external title "完整面板", right "交互细节". Leave enough vertical room for the extra comparison strip and the bottom version/footer controls. All numbers and email are demonstration values. Do not crop footer to fit.

Mandatory layout on LEFT full panel, in EXACT order:
1 existing app header, black app icon, "Codex 用量", PLUS badge, "preview@example.com".
2 quota rows exactly as image 1: 5小时 90%, 7天 10%, reset dates as shown.
3 existing full "重置卡" gray card, action "使用重置卡", ×3, all THREE expiry rows intact. Preserve each row and current placement.
4 existing full "Tibo 重置动态" gray card, both text lines and green status intact. Do not collapse or shorten either card.
5 Immediately beneath Tibo, move the three-period usage table UP:
heading exact "用量情况", native orange stacked-layers icon at left, collapse-up chevron at right. Heading contains only icon, "用量情况", chevron. No source badge.
Table headers "周期" "总量" "输入" "输出".
Rows with disclosure chevrons:
"今天" "4.87M" "4.55M" "320K"
"近 7 天" "74.94M" "72.71M" "2.23M"
"近 30 天" "687.35M" "677.87M" "9.48M".
All three model disclosures collapsed on left. Quiet text link "统计范围" below table.
6 BELOW this table, heading exact "每日用量", left icon MUST be the three ORANGE VERTICAL BARS of different heights from reference 3. Header contains just the vertical bar icon and "每日用量", with no badge. Do not use stacked-layers icon here.
Keep large demo number "2.40B" and small "累计 Token" underneath heading. Keep 30-bar chart in orange below it with sparse x ticks "10-07", "10-22", "11-05", quiet "近 30 天 · 截至 11-05".
Immediately under chart/caption ADD the comparison strip from reference 2: light gray rounded horizontal strip, two equally balanced centered items divided by thin vertical gray rule. Left exact "较昨日 +18%" with +18% in rust orange. Right exact "较前7天 −6%" with −6% in green. Both items MUST appear visibly at the same time.
7 collapsed "工具明细" row, native small list symbol at left and chevron at right.
8 Footer, retain actual app's version layout, not a concept-preview replacement:
left small gray "最近尝试刷新 14:25"; right visible small gray clickable-looking "版本 v1.0.18".
Below orange "立即刷新" button, checked native checkbox "开机自启", trailing "退出". Preserve these controls and spacing. No "概念预览" in footer.

RIGHT interaction detail inset, reorder to mirror left:
A. Start with "用量情况" title and stacked-layers symbol, no badge, three-period table.
Today expanded showing 4.87M / 4.55M / 320K and two inset model rows directly below:
"gpt-6.1-sol" "2.90M" "2.70M" "200K"
"gpt-6.1" "1.97M" "1.85M" "120K".
Then collapsed 近7天 and 近30天 rows with same numbers as left.
B. Then "每日用量" title with the correct orange VERTICAL BAR symbol from reference 3, no badge, "2.40B" and "累计 Token".
Chart with a mouse pointer hovering final bar and immediate floating tooltip exact "11 月 5 日 · 12.60M Token". Caption "近 30 天 · 截至 11-05".
The exact same comparison strip, both "较昨日 +18%" and "较前7天 −6%", must be visible below.
C. Then expanded "工具明细", native segment control "今天 | 7 天 | 30 天", 今天 selected.
Only text names + thin uniform orange bars + aligned totals, no logos/Emoji:
Proma 2.10M
Codex 1.50M
Claude Code 920K
Hermes 350K.
Bars should occupy respectively about 43%,31%,19%,7% of their gray full tracks, representing shares of the 4.87M local total.
D. A compact footer metadata row may show "最近尝试刷新 14:25" and "版本 v1.0.18" to retain the visible version control in detail too.

Visual constraints: all Chinese legible, aligned numerals, tasteful compact native density. Across BOTH panes, the only statistical section titles are "用量情况", "每日用量", "工具明细". No standalone source pills beside titles. Leave technical scope explanations out of this prototype UI. All original reset/Tibo content remains intact. Keep displayed version and footer action entry, while update interactions remain represented by that version control. No new update banners, no new version number, no release announcement, no fee estimate or explanatory marketing copy. Restore comparison strip and use correct daily icon; those two user references are mandatory.
