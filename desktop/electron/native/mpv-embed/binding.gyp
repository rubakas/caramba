{
  "targets": [
    {
      "target_name": "mpv_embed",
      "sources": [ "src/binding.mm" ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")",
        "<(module_root_dir)/../../../vendor/mpv-<!@(node -p \"process.arch === 'x64' ? 'x64' : 'arm64'\")/include"
      ],
      "libraries": [
        "<(module_root_dir)/../../../vendor/mpv-<!@(node -p \"process.arch === 'x64' ? 'x64' : 'arm64'\")/lib/libmpv.dylib"
      ],
      "defines": [ "NAPI_DISABLE_CPP_EXCEPTIONS" ],
      "cflags!": [ "-fno-exceptions" ],
      "cflags_cc!": [ "-fno-exceptions" ],
      "xcode_settings": {
        "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
        "CLANG_CXX_LIBRARY": "libc++",
        "MACOSX_DEPLOYMENT_TARGET": "11.0",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "OTHER_CFLAGS": [ "-fobjc-arc" ],
        "OTHER_LDFLAGS": [
          "-Wl,-rpath,@loader_path/../../../../../vendor/mpv-arm64/lib",
          "-Wl,-rpath,@loader_path/../../../../../vendor/mpv-x64/lib",
          "-Wl,-rpath,@executable_path/../Resources/mpv/lib"
        ]
      },
      "link_settings": {
        "libraries": [
          "$(SDKROOT)/System/Library/Frameworks/Cocoa.framework"
        ]
      }
    }
  ]
}
