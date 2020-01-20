//
//  AppDelegate.swift
//  TextDetector
//
//  Created by Tarek Sabry on 1/14/20.
//  Copyright © 2020 Tarek Sabry. All rights reserved.
//

import UIKit
import Firebase

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FirebaseApp.configure()
        
        return true
    }


}
