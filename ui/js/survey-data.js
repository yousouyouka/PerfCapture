'use strict';
/* 问卷调查数据（本轮纯前端，不接后端提交）
   每项字段：
     id        唯一键（字符串）
     title     问卷标题
     desc      一两句说明
     status    'open' 进行中 | 'closed' 已结束
     questions 题目数（数字，可省）
     minutes   预计填写时长（分钟，数字，可省）
     date      日期 'YYYY-MM-DD'（可省）
     url       问卷链接；为空表示暂未开放（「开始填写」按钮禁用）
   规则：
   - 空数组 → 问卷页显示「暂无问卷」；
   - 新问卷加在数组最前面（页面按数组顺序渲染）。 */
window.PerfSurveys = [];
