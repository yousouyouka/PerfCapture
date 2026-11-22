'use strict';
/* 扩展中心数据（前端回退镜像：仅当宿主尚未下发 extensions 时展示）
   真正的事实来源是宿主 extensions.json + 状态机；本文件只在 init 之前兜底。
   批次 D 起 RTSS 已发布（available:true），回退态标为 notInstalled；
   cpu-sensor 是内置能力（builtin），回退态标为 enabled。
   2026-11-22 起 frameview / etw-consumer 已删除，注册表不再有"规划中"条目。
   宿主就绪后 apply() 会用真实状态覆盖。
   每项字段：
     id / name / desc / category / metrics / depends / size / permission /
     platform / cost / source / status（见 extensions.js 的 STATUS 映射）
     available  false=规划中（按钮禁用）；true=已发布（可显示安装/启用/关闭）
   规则：
   - 状态、按钮、筛选等界面文案走 i18n，不在 extensions.js 里写死中文；
   - 数组为空时显示「暂无扩展」空状态。 */
window.PerfExtensions = [
  {
    id: 'rtss-shm',
    name: 'RTSS 共享内存桥接',
    desc: '软件内静默下载并安装一份独立的 RTSS，读取它暴露的帧数据，提供亚秒级 FPS 与 1% Low。绝大多数游戏正常，极少数游戏（如终末地）可能误判并关闭 DLSS；遇到时关闭该扩展即可结束本软件安装的副本并消除影响，无需卸载。',
    category: 'datasource',
    metrics: ['FPS', '帧时间', '1% Low'],
    depends: '由扩展中心下载安装（本机已有 RTSS 会被无视）',
    size: '约 25 MB（安装后约 50 MB）',
    permission: '安装时一次 UAC 确认；不设开机自启',
    platform: 'Windows · 全平台',
    cost: '低',
    source: 'RivaTuner Statistics Server · 官方安装包（固定版本 + SHA-256 校验）',
    version: '1.1.0',
    available: true,
    managed: true,
    status: 'notInstalled'
  },
  {
    id: 'cpu-sensor',
    name: 'CPU 温度（厂商固件通道）',
    desc: '读取主板/EC 固件通过 ACPI-WMI 暴露的只读温度接口。内置能力：无需安装、不捆绑驱动；目前支持联想机型，其它品牌如实显示暂不可用。',
    category: 'sensor',
    metrics: ['CPU 温度', 'CPU 降频（固件限速）'],
    depends: '联想机型固件接口（其它品牌暂不支持）',
    size: '内置（不占额外空间）',
    permission: '随主程序以管理员运行，无需额外授权',
    platform: 'Windows · 联想机型',
    cost: '极低（约 2 秒一次只读调用）',
    source: '厂商固件 · ACPI-WMI 只读接口',
    status: 'enabled',
    builtin: true
  }
];
