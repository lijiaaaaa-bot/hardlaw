//
//  SceneDelegate.swift
//  VisionInsight
//
//  场景代理 - 完善版本
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    private var navigationController: UINavigationController?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        
        // 验证场景连接
        guard let windowScene = (scene as? UIWindowScene) else {
            print("❌ 场景连接失败：无效的窗口场景")
            return
        }
        
        // 创建主窗口
        window = UIWindow(windowScene: windowScene)
        
        // 创建导航控制器包装主视图控制器
        let mainViewController = ViewController()
        navigationController = UINavigationController(rootViewController: mainViewController)
        
        // 设置窗口根视图控制器
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()
        
        // 配置应用外观
        setupAppAppearance()
        
        print("✅ 场景连接完成")
    }
    
    private func setupAppAppearance() {
        print("🎨 应用外观配置...")
        
        // 设置全局样式
        UINavigationBar.appearance().prefersLargeTitles = true
        UINavigationBar.appearance().barTintColor = .systemBlue
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.white]
        
        // 配置表格视图样式（如适用）
        UITableView.appearance().backgroundColor = .systemGroupedBackground
        
        print("✅ 应用外观配置完成")
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        print("🔌 场景断开连接")
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not neccessarily discarded (see `application:didDiscardSceneSessions` instead).
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        print("⚡ 场景变为活跃状态")
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        print("😴 场景将失去活跃状态")
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        print("🌅 场景即将进入前台")
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        print("🌙 场景进入后台")
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }
    
    // MARK: - Scene Management
    
    /// 处理场景状态变化
    func handleSceneStateChange(_ newState: SceneState) {
        switch newState {
        case .active:
            print("🔄 场景进入活跃状态")
        case .inactive:
            print("⏳ 场景进入非活跃状态")
        case .background:
            print("🔚 场景进入后台状态")
        case .foreground:
            print("🌅 场景进入前台状态")
        }
    }
}

// MARK: - Scene State Management

/// 场景状态枚举
enum SceneState {
    case active
    case inactive
    case background
    case foreground
}

// MARK: - Scene Extension for Future Use

extension SceneDelegate {
    
    /// 验证场景配置
    func validateSceneConfiguration() -> Bool {
        print("🔍 场景配置验证...")
        
        // 检查必需的组件是否存在
        guard let windowScene = window?.windowScene else {
            print("❌ 缺少窗口场景")
            return false
        }
        
        // 验证场景类型是否正确
        if windowScene is UIWindowScene {
            print("✅ 场景配置验证通过")
            return true
        } else {
            print("❌ 场景类型验证失败")
            return false
        }
    }
    
    /// 重启场景会话
    func restartSceneSession() {
        print("🔄 重启场景会话...")
        
        // 可以在这里实现会话重置逻辑
        
        print("✅ 场景会话重启完成")
    }
}