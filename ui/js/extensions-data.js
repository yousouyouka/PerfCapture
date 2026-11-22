'use strict';
/* 扩展中心数据（前端回退镜像：仅当宿主尚未下发 extensions 时展示）
   真正的事实来源是宿主 extensions.json + 状态机；本文件只在 init 之前兜底。
   批次 D 起 RTSS 已发布（available:true），回退态标为 notInstalled；
   其余仍为 planned。宿主就绪后 apply() 会用真实状态覆盖。
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
    id: 'frameview',
    name: 'NVIDIA FrameView 适配',
    desc: '经由厂商官方接口提供帧率与帧时间。仅限 NVIDIA 显卡，授权条款待评估。',
    category: 'datasource',
    metrics: ['FPS', '帧时间'],
    depends: 'NVIDIA 显卡 + 官方 SDK',
    size: '小',
    permission: '无需驱动级权限',
    platform: 'Windows · NVIDIA',
    cost: '中',
    source: '厂商官方 SDK',
    status: 'planned'
  },
  {
    id: 'cpu-sensor',
    name: 'CPU 温度与降频',
    desc: '经用户态传感器组件提供 CPU 温度与降频原因。涉及组件由用户自行选择，安装须二次授权。',
    category: 'sensor',
    metrics: ['CPU 温度', '降频原因'],
    depends: '用户态传感器库',
    size: '中',
    permission: '安装需二次授权',
    platform: 'Windows · 全平台',
    cost: '低',
    source: '开源组件 · 用户自选',
    status: 'planned'
  },
  {
    id: 'etw-consumer',
    name: '自研高频 ETW 数据源',
    desc: '以独立消费者常驻采集帧事件，零注入。作为备选扩展实现，风险与开发成本由需要的用户自行承担，不再是主程序默认路线。',
    category: 'datasource',
    metrics: ['FPS', '帧时间', '1% Low'],
    depends: '无第三方依赖',
    size: '小',
    permission: '无需管理员 / 驱动',
    platform: 'Windows · 全平台',
    cost: '低',
    source: '项目自研 · 备选',
    status: 'planned'
  }
];
