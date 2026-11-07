# 原型生成说明

方式：内置 image_gen · 数据：虚构演示值 · 用途：PRD v0.7 评审。

参考图：`docs/images/codex-usage-v1.0.17.png`。

## 生成提示词（已脱敏）

Use case: ui-mockup.
Create one polished Chinese native macOS AppKit product prototype presentation image, roughly 1920x2048 or a similar portrait canvas. This is CodexUsage v0.7, a proposal, with ALL fabricated demonstration data. Use the referenced EXISTING screenshot for native style and for the exact structure of its reset-card and Tibo sections. NOT a website/dashboard, no phone frame. Warm off-white/light gray desktop background, rust-orange accent, graphite text, restrained green/red quota indicators, native rounded popover material with subtle shadows. Crisp SF/PingFang Chinese typography, aligned tabular numerals. Do not use purple or blue gradients.

Composition: two columns, only two quiet labels outside UI: left "完整面板", right "交互细节". Left shows ONE entire native popover with pointer, header, all content and footer, unclipped. Right shows a focused larger-detail inset of the statistics area with chart hover, model expansion, and tool expansion. The right inset is a detail view of the same proposed UI, not a second competing design. Maintain visually matching widths/proportions. The left view is the default state; the right shows selected interactions. Leave reasonable margins. Each view corresponds to an approximately 330 pt native menu popover width. Optimize legibility over decoration.

LEFT COMPLETE DEFAULT PANEL top to bottom:
1. Header: reference black rounded-square CodexUsage app icon with white angle brackets and tiny rust underline. Title "Codex 用量", small "PLUS" text badge same style as reference warm color. Subtitle "preview@example.com".
2. Quota: right column header "重置时间". Row "5 小时" green "90%" with long green bar, right "11-06 19:25". Row "7 天" red "10%" with short red bar, right "11-13 14:25".
3. RESET CARD SECTION must keep EXISTING full layout, NOT compress to one upcoming date: rounded soft gray inset card, header native outlined ticket/calendar icon, "重置卡", small action "使用重置卡", right "×3". Three visible full rows:
"全额重置卡" right "2026-11-08 14:25 过期" (rust warning)
"全额重置卡" right "2026-12-04 14:25 过期"
"全额重置卡" right "2026-12-05 14:25 过期".
Preserve reference density/layout/action placement.
4. TIBO SECTION must keep its own full rounded soft-gray inset card, not collapsed to a one-line row: heading "Tibo 重置动态"; below line "预估 北京时间 11月4日 15:00–20:00"; below green check status "11-05 重置卡已发放". Match reference structure. Existing status symbol is preserved.
5. New account statistics section, compact and native:
Header "账号用量" small trailing "官方". One prominent but restrained number "2.40B" with small label "累计 Token". This is account-level total, NOT in the local table.
Below it a compact 30-bar daily chart, rust orange muted bars, very light baseline, sparse x labels "10-07", "10-22", "11-05". One quiet small caption beneath "近 30 天 · 截至 11-05". Do not add input/output, models, tool breakdown, comparison percentages or other stats to this official account section.
6. New local statistics section:
Header "本机用量" with small trailing "本机" and native collapse chevron up. Table columns "周期" "总量" "输入" "输出".
Three rows, each with disclosure affordance:
"今天" "4.87M" "4.55M" "320K"
"近 7 天" "74.94M" "72.71M" "2.23M"
"近 30 天" "687.35M" "677.87M" "9.48M".
Total column rust-orange. All model rows are collapsed in left panel. No lifetime row in local table.
Tiny quiet text link "统计范围" below table.
7. Single collapsed header row "工具明细" right chevron. No individual tool rows in left default panel.
8. Divider and footer: small gray left "最近刷新 14:25", right "概念预览". Bottom button "立即刷新" rust filled native button, checked checkbox "开机自启", quiet trailing "退出". Keep entire footer visible.

RIGHT INTERACTION DETAIL INSET:
Only statistics from the same panel, without repeating reset cards, quota or account header. Clear separation of account chart and local data.
A. Account area same heading "账号用量" trailing "官方", same "2.40B" "累计 Token" and same chart. Show pointer hovering over final day bar, selected bar darker with tiny native immediate floating tooltip "11 月 5 日 · 12.60M Token". Tooltip above chart within inset boundaries, no overlap with section title. Small caption "近 30 天 · 截至 11-05". The numbers are demo data.
B. "本机用量" same table. Today row shows expanded chevron and same totals 4.87M / 4.55M / 320K. Directly under TODAY, indent two model rows aligned to same numeric columns:
"gpt-6.1-sol" "2.90M" "2.70M" "200K"
"gpt-6.1" "1.97M" "1.85M" "120K"
Then show collapsed "近 7 天" row with 74.94M / 72.71M / 2.23M and collapsed "近 30 天" row with 687.35M / 677.87M / 9.48M. Models expand inline under their period, NO separate model-card or unrelated model-details footer.
C. "工具明细" expanded chevron, native compact segmented selector "今天 | 7 天 | 30 天", 今天 selected. Four rows ONLY text names, thin rust bars and right-aligned totals, sorted:
"Proma" "2.10M"
"Codex" "1.50M"
"Claude Code" "920K"
"Hermes" "350K".
No tool logos, no row icons, no Emoji. Use consistent single accent color for bars. These are LOCAL source totals, visually separated from official cumulative and daily chart.

Constraints: Accurate Chinese text, restrained AppKit look, legible compact table, no extra marketing sentences, arrows/callout annotations, fee estimates or decorative badges. Account total uses fabricated 2.40B. Official stats have no model/input/output decomposition. Local table has only three periods. Reset and Tibo layout must retain their existing full content. The overall artboard should make the default layout and hover/expanded behavior easy to assess.
