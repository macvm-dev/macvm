//! 不是从宿主可信通道（vsock，或来自默认网关的 TCP）连入的连接，要先过质询应答才能发请求：
//! 代理发 `Challenge`，对方回 `Answer`，`auth` 是以共享令牌为密钥、对 `challenge` 原文算的 HMAC-SHA256（十六进制小写）。
//! 令牌不上网线，旁听到的应答换了质询就作废。

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

/// 质询的随机字节数。
pub const CHALLENGE_BYTES: usize = 32;

#[derive(Debug, Serialize, Deserialize)]
pub struct Challenge {
    pub challenge: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Answer {
    pub auth: String,
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

fn mac(token: &str, challenge: &str) -> Hmac<Sha256> {
    let mut mac = Hmac::<Sha256>::new_from_slice(token.as_bytes()).expect("HMAC 接受任意长度的密钥");
    mac.update(challenge.as_bytes());
    mac
}

pub fn answer(token: &str, challenge: &str) -> String {
    hex(&mac(token, challenge).finalize().into_bytes())
}

/// 常数时间比较，不从耗时泄露应答的前缀。
pub fn verify(token: &str, challenge: &str, auth: &str) -> bool {
    unhex(auth).is_some_and(|tag| mac(token, challenge).verify_slice(&tag).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    struct Sample {
        token: String,
        challenge: String,
        auth: String,
    }

    #[test]
    fn auth_fixtures() {
        for line in include_str!("../fixtures/auth.jsonl").lines() {
            let s: Sample = serde_json::from_str(line).unwrap();
            assert_eq!(answer(&s.token, &s.challenge), s.auth);
            assert!(verify(&s.token, &s.challenge, &s.auth));
            let flipped = if s.auth.starts_with('0') { "1" } else { "0" };
            assert!(!verify(&s.token, &s.challenge, &format!("{flipped}{}", &s.auth[1..])));
            assert!(!verify("other", &s.challenge, &s.auth));
            assert!(!verify(&s.token, &s.challenge, "zz"));
        }
    }
}
