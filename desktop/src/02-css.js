// ============================================================================
// §2 CSS (every colour comes from the host's --ui-* theme variables)
// ============================================================================
const CSS = `
.hs-root{position:relative;height:100%;min-height:0;display:flex;flex-direction:column;color:var(--ui-text-primary);font-size:13px;line-height:1.45}
.hs-root *,.hs-modal *{box-sizing:border-box}
.hs-scroll{flex:1;min-height:0;overflow:auto}
.hs-page{padding:18px 22px 40px;max-width:1280px}
.hs-head{display:flex;align-items:center;gap:12px;margin-bottom:12px;flex-wrap:wrap}
.hs-head h1{font-size:17px;margin:0;font-weight:600}
.hs-domain{color:var(--ui-text-tertiary)}
.hs-grow{flex:1}
.hs-tabs{display:flex;gap:2px;border-bottom:1px solid var(--ui-stroke-secondary);margin-bottom:16px;overflow-x:auto}
.hs-tab{padding:7px 12px;border:0;background:none;color:var(--ui-text-tertiary);cursor:pointer;border-bottom:2px solid transparent;margin-bottom:-1px;white-space:nowrap;font:inherit}
.hs-tab:hover{color:var(--ui-text-primary)}
.hs-tab.on{color:var(--ui-text-primary);border-bottom-color:var(--ui-accent)}
.hs-tab .hs-n{font-size:11px;margin-left:4px;padding:0 5px;border-radius:8px;background:var(--ui-bg-card);color:var(--ui-text-tertiary)}
.hs-ghost{border:0;background:none;color:var(--ui-text-tertiary);cursor:pointer;padding:2px 6px;border-radius:4px;font:inherit}
.hs-ghost:hover{background:var(--ui-row-hover-background);color:var(--ui-text-primary)}
.hs-ghost.hs-x{padding:0 2px}
.hs-danger{color:var(--ui-red)}
.hs-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;padding:1px 7px;border-radius:10px;background:var(--ui-bg-card);color:var(--ui-text-secondary);border:1px solid var(--ui-stroke-tertiary);white-space:nowrap}
.hs-badge.red{color:var(--ui-red);border-color:color-mix(in srgb,var(--ui-red) 30%,transparent);background:color-mix(in srgb,var(--ui-red) 8%,transparent)}
.hs-badge.yellow{color:var(--ui-yellow);border-color:color-mix(in srgb,var(--ui-yellow) 30%,transparent);background:color-mix(in srgb,var(--ui-yellow) 8%,transparent)}
.hs-badge.green{color:var(--ui-green);border-color:color-mix(in srgb,var(--ui-green) 30%,transparent);background:color-mix(in srgb,var(--ui-green) 8%,transparent)}
.hs-badge.accent{color:var(--ui-accent);border-color:color-mix(in srgb,var(--ui-accent) 30%,transparent);background:color-mix(in srgb,var(--ui-accent) 8%,transparent)}
.hs-text-red{color:var(--ui-red)}
.hs-text-yellow{color:var(--ui-yellow)}
.hs-text-green{color:var(--ui-green)}
.hs-kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;margin-bottom:18px}
.hs-kpi{background:var(--ui-bg-card);border:1px solid var(--ui-stroke-tertiary);border-radius:8px;padding:10px 12px;cursor:pointer;text-align:left;font:inherit;color:inherit}
.hs-kpi:hover{border-color:var(--ui-stroke-secondary)}
.hs-kpi .hs-v{font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}
.hs-kpi .hs-l{color:var(--ui-text-tertiary);font-size:12px}
.hs-kpi .hs-s{font-size:11.5px;margin-top:2px}
.hs-grid2{display:grid;grid-template-columns:1.4fr 1fr;gap:16px;align-items:start}
.hs-grid2.hs-gpo{grid-template-columns:1.3fr 1fr}
@media (max-width:900px){.hs-grid2,.hs-grid2.hs-gpo{grid-template-columns:1fr}}
.hs-card{background:var(--ui-bg-card);border:1px solid var(--ui-stroke-tertiary);border-radius:8px;overflow:hidden}
.hs-card h3{margin:0;font-size:12.5px;font-weight:600;padding:9px 12px;border-bottom:1px solid var(--ui-stroke-tertiary);display:flex;align-items:center;gap:8px}
.hs-card h3 .hs-sub{font-weight:400;color:var(--ui-text-tertiary)}
.hs-card-body{padding:12px;display:grid;gap:12px}
.hs-table{width:100%;border-collapse:collapse}
.hs-table th{font-weight:500;color:var(--ui-text-tertiary);font-size:11.5px;text-align:left;padding:6px 12px;border-bottom:1px solid var(--ui-stroke-tertiary);white-space:nowrap}
.hs-table td{padding:7px 12px;border-bottom:1px solid var(--ui-stroke-tertiary);vertical-align:middle}
.hs-table tr:last-child td{border-bottom:0}
.hs-table tbody tr.click{cursor:pointer}
.hs-table tbody tr.click:hover{background:var(--ui-row-hover-background)}
.hs-table tbody tr.sel{background:var(--ui-row-active-background)}
.hs-table td.hs-empty-row{text-align:center;padding:24px;color:var(--ui-text-tertiary)}
.hs-nowrap{white-space:nowrap}
.hs-mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
.hs-muted{color:var(--ui-text-tertiary)}
.hs-small{font-size:12px}
.hs-tiny{font-size:11px}
.hs-p{margin:0 0 8px}
.hs-stack{display:grid;gap:10px}
.hs-toolbar{display:flex;gap:8px;align-items:center;margin-bottom:10px;flex-wrap:wrap}
.hs-search{flex:0 1 300px;border:1px solid var(--ui-stroke-secondary);background:var(--ui-bg-input);border-radius:6px;padding:5px 10px;color:var(--ui-text-primary);font:inherit}
.hs-chip{border:1px solid var(--ui-stroke-secondary);background:none;border-radius:12px;padding:2px 10px;font-size:12px;cursor:pointer;color:var(--ui-text-secondary);font-family:inherit}
.hs-chip.on{background:var(--ui-row-active-background);border-color:color-mix(in srgb,var(--ui-accent) 40%,transparent);color:var(--ui-text-primary)}
.hs-seg{display:inline-flex;border:1px solid var(--ui-stroke-secondary);border-radius:6px;overflow:hidden;align-self:flex-start}
.hs-seg button{border:0;background:none;padding:3px 10px;cursor:pointer;color:var(--ui-text-tertiary);font:inherit}
.hs-seg button.on{background:var(--ui-row-active-background);color:var(--ui-text-primary)}
.hs-loading{display:flex;align-items:center;gap:8px;color:var(--ui-text-tertiary);padding:16px 4px}
.hs-drawer{position:absolute;top:0;right:0;bottom:0;width:420px;max-width:100%;background:var(--ui-bg-elevated);border-left:1px solid var(--ui-stroke-secondary);box-shadow:-12px 0 30px color-mix(in srgb,var(--ui-base) 14%,transparent);overflow:auto;z-index:20}
.hs-dh{display:flex;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid var(--ui-stroke-tertiary);position:sticky;top:0;background:var(--ui-bg-elevated);z-index:1}
.hs-avatar{width:34px;height:34px;border-radius:50%;background:color-mix(in srgb,var(--ui-accent) 20%,transparent);display:grid;place-items:center;font-weight:600;color:var(--ui-accent);flex:none}
.hs-sec{padding:12px 16px;border-bottom:1px solid var(--ui-stroke-tertiary)}
.hs-sec h4,.hs-label{margin:0 0 8px;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;color:var(--ui-text-quaternary);font-weight:500}
.hs-kv{display:grid;grid-template-columns:130px 1fr;gap:4px 10px;font-size:12.5px}
.hs-kv-row{display:contents}
.hs-kv .hs-k{color:var(--ui-text-tertiary)}
.hs-kv>.hs-kv-row>span:last-child{min-width:0;overflow-wrap:anywhere}
.hs-actions{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.hs-row{display:flex;gap:8px;align-items:center;margin-bottom:6px}
.hs-callout{border-radius:6px;padding:8px 10px;font-size:12.5px;display:flex;gap:8px;align-items:flex-start}
.hs-callout.red{background:color-mix(in srgb,var(--ui-red) 9%,transparent);border:1px solid color-mix(in srgb,var(--ui-red) 25%,transparent)}
.hs-callout.yellow{background:color-mix(in srgb,var(--ui-yellow) 9%,transparent);border:1px solid color-mix(in srgb,var(--ui-yellow) 25%,transparent)}
.hs-callout.accent{background:color-mix(in srgb,var(--ui-accent) 8%,transparent);border:1px solid color-mix(in srgb,var(--ui-accent) 25%,transparent)}
.hs-modal{width:480px;max-width:calc(100vw - 32px)}
.hs-modal.hs-modal-wide{width:680px;max-width:min(680px,calc(100vw - 32px)) !important}
.hs-modal-sub{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.hs-modal-body{display:grid;gap:10px;font-size:13px;color:var(--ui-text-primary);max-height:60vh;overflow:auto}
.hs-whatif{background:var(--ui-bg-chrome);border:1px solid var(--ui-stroke-tertiary);border-radius:6px;padding:8px 10px;font-family:ui-monospace,Menlo,monospace;font-size:11.5px;white-space:pre-wrap;margin:0;color:var(--ui-text-secondary);overflow-wrap:anywhere}
.hs-secret{font-size:15px;color:var(--ui-text-primary);text-align:center;letter-spacing:.06em;user-select:all}
.hs-input{width:100%;border:1px solid var(--ui-stroke-secondary);background:var(--ui-bg-input);border-radius:6px;padding:6px 10px;color:var(--ui-text-primary);font:inherit}
textarea.hs-input{min-height:64px;resize:vertical}
.hs-field{font-size:12px;color:var(--ui-text-tertiary);display:grid;gap:4px}
.hs-check{font-size:12.5px;color:var(--ui-text-secondary);display:flex;gap:6px;align-items:center;cursor:pointer}
.hs-two{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.hs-tier{font-size:10.5px;font-weight:600;letter-spacing:.04em;padding:1px 6px;border-radius:4px;white-space:nowrap}
.hs-tier-R{background:var(--ui-bg-card);color:var(--ui-text-tertiary)}
.hs-tier-W{background:color-mix(in srgb,var(--ui-yellow) 14%,transparent);color:var(--ui-yellow)}
.hs-tier-H{background:color-mix(in srgb,var(--ui-red) 14%,transparent);color:var(--ui-red)}
.hs-tier-P{background:var(--ui-text-primary);color:var(--ui-bg-editor)}
.hs-hosts{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:12px}
.hs-hcard{background:var(--ui-bg-card);border:1px solid var(--ui-stroke-tertiary);border-radius:8px;padding:12px}
.hs-hcard.bad{border-color:color-mix(in srgb,var(--ui-red) 40%,transparent)}
.hs-hcard.warn{border-color:color-mix(in srgb,var(--ui-yellow) 40%,transparent)}
.hs-hcard .hs-top{display:flex;align-items:center;gap:8px;margin-bottom:8px}
.hs-hcard .hs-top b{flex:1}
.hs-bar{height:6px;border-radius:3px;background:var(--ui-stroke-tertiary);overflow:hidden;margin:8px 0 4px}
.hs-drawer.hs-drawer-wide{width:560px}
.hs-bar.hs-bar-inline{display:inline-block;width:48px;margin:0 6px 1px 0;vertical-align:middle}
.hs-bar.low i{background:var(--ui-red)}
.hs-selbar{padding:6px 10px;border:1px solid var(--ui-stroke-secondary);border-radius:6px;background:var(--ui-row-active-background)}
.hs-select{flex:0 0 auto;width:auto;min-width:160px}
.hs-clickrow{cursor:pointer;padding:4px 6px;border-radius:6px}
.hs-clickrow:hover{background:var(--ui-row-hover-background)}
.hs-table tbody tr.sel{background:var(--ui-row-active-background)}
.hs-bar i{display:block;height:100%;background:var(--ui-accent);transition:width .4s}
.hs-empty{max-width:480px;margin:60px auto;text-align:center}
.hs-empty .hs-big{font-size:34px;margin-bottom:8px}
.hs-empty h2{margin:0 0 6px;font-size:17px}
.hs-form{display:grid;gap:10px;text-align:left;margin-top:16px}
.hs-checklist{margin:0;padding-left:18px;color:var(--ui-text-secondary);font-size:12.5px;display:grid;gap:2px}
.hs-end{display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap}
.hs-radio{display:flex;gap:6px;align-items:center;font-size:12.5px;cursor:pointer}
.hs-root{--hs-series-0:var(--ui-accent,#4c8bf5);--hs-series-1:var(--ui-green,#3fb950);--hs-series-2:var(--ui-yellow,#d29922);--hs-series-3:var(--ui-red,#f85149);--hs-series-4:var(--ui-text-secondary,#8b949e);--hs-series-5:var(--ui-text-tertiary,#6e7681)}
.hs-chart{margin:0;display:flex;flex-direction:column;gap:8px;color:var(--ui-text-primary)}
.hs-chart-donut{flex-direction:row;align-items:center;gap:16px;flex-wrap:wrap}
.hs-chart-center{fill:var(--ui-text-primary);font-size:16px;font-weight:600}
.hs-chart-btn{appearance:none;border:0;background:none;color:inherit;font:inherit;text-align:inherit;cursor:pointer;width:100%}
.hs-chart-histlabels{display:flex;gap:0}
.hs-chart-histcol{flex:1 1 0;min-width:0;display:flex;flex-direction:column;align-items:center;padding:2px 0;border-radius:4px}
.hs-chart-histcount{font-variant-numeric:tabular-nums;color:var(--ui-text-primary);font-size:12px}
.hs-chart-histlabel{color:var(--ui-text-tertiary);font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:100%}
.hs-chart .hs-clickable{cursor:pointer}
.hs-chart [role=button]:focus-visible,.hs-chart-btn:focus-visible{outline:2px solid var(--ui-accent);outline-offset:2px}
.hs-chart path.hs-clickable:hover,.hs-chart rect.hs-clickable:hover{opacity:.8}
.hs-chart-legend{list-style:none;margin:0;padding:0;display:grid;gap:3px;font-size:12.5px}
.hs-chart-legend-row{display:flex;align-items:center;gap:8px;padding:1px 4px;border-radius:4px}
.hs-chart-btn.hs-chart-legend-row:hover,.hs-chart-btn.hs-chart-histcol:hover{background:var(--ui-bg-elevated)}
.hs-chart-swatch{width:10px;height:10px;border-radius:2px;flex:none}
.hs-chart-legend-label{flex:1;color:var(--ui-text-secondary)}
.hs-chart-legend-value{color:var(--ui-text-primary);font-variant-numeric:tabular-nums}
.hs-chart-bars{gap:4px}
.hs-chart-barrow{display:grid;grid-template-columns:minmax(80px,30%) 1fr auto;align-items:center;gap:8px;padding:2px 4px;border-radius:4px}
.hs-chart-barrow.hs-clickable:hover{background:var(--ui-bg-elevated)}
.hs-chart-barlabel{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--ui-text-secondary)}
.hs-chart-bartrack{height:8px;border-radius:4px;background:var(--ui-stroke-tertiary);overflow:hidden}
.hs-chart-bartrack i{display:block;height:100%}
.hs-chart-barvalue{font-variant-numeric:tabular-nums;color:var(--ui-text-primary)}
.hs-chart-spark{flex-direction:row;align-items:center;gap:8px}
.hs-chart-sparkvalue{color:var(--ui-text-secondary);font-variant-numeric:tabular-nums}
.hs-stat{min-width:120px}
.hs-link{border:0;background:none;padding:0;color:var(--ui-accent);cursor:pointer;font:inherit;text-decoration:underline}
.hs-grid3{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;align-items:start}
.hs-grid3 .hs-span3{grid-column:1 / -1}
.hs-grid2.hs-even{grid-template-columns:1fr 1fr}
@media (max-width:900px){.hs-grid3,.hs-grid2.hs-even{grid-template-columns:1fr}}
.hs-stat{min-width:0;display:flex}
.hs-stat .hs-kpi{width:100%;display:flex;flex-direction:column;justify-content:flex-start}
.hs-kpi .hs-l,.hs-kpi .hs-s{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hs-kpis{grid-template-columns:repeat(auto-fit,minmax(150px,1fr))}
.hs-kpi{transition:border-color .15s,transform .15s,box-shadow .15s}
.hs-kpi:hover{transform:translateY(-1px);box-shadow:0 4px 14px color-mix(in srgb,var(--ui-base,#000) 8%,transparent)}
@keyframes hs-in{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.hs-card,.hs-hero,.hs-kpis{animation:hs-in .35s ease-out both}
@media (prefers-reduced-motion:reduce){.hs-card,.hs-hero,.hs-kpis,.hs-score-arc{animation:none!important;transition:none!important}}
.hs-hero{display:grid;grid-template-columns:minmax(260px,330px) 1fr;gap:18px;padding:16px 18px;border-radius:12px;border:1px solid color-mix(in srgb,var(--ui-accent) 22%,var(--ui-stroke-tertiary));background:radial-gradient(120% 140% at 0% 0%,color-mix(in srgb,var(--ui-accent) 10%,transparent),transparent 60%),var(--ui-bg-card)}
@media (max-width:900px){.hs-hero{grid-template-columns:1fr}}
.hs-hero-side{display:flex;gap:16px;align-items:center}
.hs-hero-copy{display:grid;gap:6px;justify-items:start}
.hs-hero-title{font-size:16px;font-weight:600}
.hs-score{position:relative;margin:0;flex:none}
.hs-score svg{display:block}
.hs-score-track{fill:none;stroke:var(--ui-stroke-tertiary);stroke-width:9}
.hs-score-arc{fill:none;stroke-width:9;stroke-linecap:round;transition:stroke-dasharray .8s ease-out}
.hs-score.success .hs-score-arc{stroke:var(--ui-green)}
.hs-score.warning .hs-score-arc{stroke:var(--ui-yellow)}
.hs-score.danger .hs-score-arc{stroke:var(--ui-red)}
.hs-score-text{position:absolute;inset:0;display:grid;place-content:center;text-align:center;line-height:1.1}
.hs-score-text b{font-size:28px;font-weight:650;font-variant-numeric:tabular-nums}
.hs-score-text span{font-size:10.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--ui-text-tertiary)}
.hs-attn{list-style:none;margin:0;padding:0;display:grid;gap:4px;align-content:start}
.hs-attn-row{display:flex;align-items:center;gap:10px;padding:5px 8px;border-radius:8px}
.hs-attn-row:hover{background:var(--ui-row-hover-background)}
.hs-attn-dot{width:8px;height:8px;border-radius:50%;flex:none;background:var(--ui-yellow)}
.hs-attn-row.danger .hs-attn-dot{background:var(--ui-red);box-shadow:0 0 0 3px color-mix(in srgb,var(--ui-red) 18%,transparent)}
.hs-attn-main{flex:1;min-width:0;display:flex;gap:10px;align-items:baseline;border:0;background:none;padding:0;text-align:left;color:inherit;font:inherit;cursor:pointer}
.hs-attn-main b{font-weight:550;white-space:nowrap}
.hs-attn-main span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hs-attn-empty{padding:18px 8px}
.hs-ask{display:inline-flex;align-items:center;gap:5px;flex:none;border:1px solid color-mix(in srgb,var(--ui-accent) 35%,transparent);background:color-mix(in srgb,var(--ui-accent) 7%,transparent);color:var(--ui-accent);border-radius:999px;padding:2px 10px;font:inherit;font-size:12px;cursor:pointer;white-space:nowrap;transition:background .15s,transform .15s}
.hs-ask:hover{background:color-mix(in srgb,var(--ui-accent) 15%,transparent)}
.hs-ask:active{transform:scale(.97)}
.hs-ask.primary{background:var(--ui-accent);color:var(--ui-bg-editor,#fff);border-color:var(--ui-accent);padding:5px 14px;font-size:12.5px;margin-top:4px}
.hs-ask.primary:hover{background:color-mix(in srgb,var(--ui-accent) 88%,#000)}
.hs-ask-spark{font-size:11px}
.hs-ask:focus-visible,.hs-attn-main:focus-visible{outline:2px solid var(--ui-accent);outline-offset:2px}
`;
