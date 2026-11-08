// 本地占位；CI 构建时会用真实 git 短 SHA 覆盖此文件
enum BuildStamp {
    static let gitSHA = "local"
}
