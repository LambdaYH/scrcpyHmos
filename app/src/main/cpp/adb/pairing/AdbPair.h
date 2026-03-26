#pragma once

#include <string>

namespace scrcpy::pairing {

std::string AdbPair(const std::string& hostPort, const std::string& pairingCode, const std::string& publicKeyPath,
                    const std::string& privateKeyPath);

}  // namespace scrcpy::pairing
