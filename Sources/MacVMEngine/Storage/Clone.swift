public import Foundation
import MacVMModel

public enum Clone {
    /// APFS 同卷时用 `clonefile` 零拷贝；跨卷时退回保留稀疏性的普通复制。
    public static func file(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        guard errno == EXDEV || errno == ENOTSUP else {
            throw MacVMError.posix(String(l10n: "Couldn't clone \(source.lastPathComponent)"))
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_DATA_SPARSE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw MacVMError.posix(String(l10n: "Couldn't copy \(source.lastPathComponent)"))
        }
    }
}
