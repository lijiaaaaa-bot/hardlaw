# VisionInsight iOS 应用

## 项目简介

VisionInsight 是一个基于 iPhone 16 Pro Max 原生 AI 能力的探索应用，充分利用 Apple Neural Engine 和系统轻量LLM进行智能处理。

## 核心特性

### 🚀 AI能力检测
- 特征向量提取
- 人体姿态识别  
- 手部关键点检测
- 人像分割
- 文档边界识别
- 面部关键点检测

### 🔍 意图识别
- 基于系统原生LLM的自然语言理解
- 实时语义分析
- 智能任务路由

### 🎥 实时分析
- 直接连接摄像头实时处理
- NPU硬件加速  
- 流式多任务并行

## 技术架构

### 本地化优势
- ✅ 所有计算在设备端完成
- ✅ 零网络流量消耗  
- ✅ 完全隐私保护
- ✅ 毫秒级响应性能

### 系统集成
```swift
// 使用系统Vision框架（全部在NPU上执行）
let request = VNDetectHumanBodyPoseRequest { [weak self] request, error in
    // 完全本地处理，无需网络
}
request.usesCPUOnly = false  // 自动使用NPU
```

## 部署说明

1. 使用 Xcode 连接 iPhone 16 Pro Max
2. 建议iOS系统版本：17.0+
3. 应用自动检测并展示所有可用的AI能力
4. 所有处理均在本地完成，无需互联网连接

## 隐私保护

- 数据完整保留在设备端
- 无网络传输  
- 系统级数据加密
- 符合GDPR/CCPA等合规要求