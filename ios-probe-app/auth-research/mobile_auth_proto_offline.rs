//! Offline-only, protocol-shape regression fixtures for mobile login.
//! This module is NOT linked into the iOS application and CANNOT send requests.
//! Only synthetic protobuf values. No passwords, user identifiers, or SMS secrets.
#![forbid(unsafe_code)]

#[derive(Debug, PartialEq, Eq)]
pub enum AuthShapeError {
    Empty,
    Oversized,
    InvalidCode,
}

fn varint(mut n: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let mut b = (n & 0x7f) as u8;
        n >>= 7;
        if n != 0 { b |= 0x80; }
        out.push(b);
        if n == 0 { break; }
    }
    out
}

fn bytes_field(n: u32, v: &[u8]) -> Vec<u8> {
    let mut out = varint((u64::from(n) << 3) | 2);
    out.extend(varint(v.len() as u64));
    out.extend(v);
    out
}

/// Schema-only, synthetic test encoder. Does not compute/accept real password
/// hashes or send a request. Protobuf tags match manual-auth declarations.
pub fn synthetic_secmanualauth_frame(
    rsa_body: &[u8],
    aes_body: &[u8],
) -> Result<Vec<u8>, AuthShapeError> {
    if rsa_body.is_empty() || aes_body.is_empty() {
        return Err(AuthShapeError::Empty);
    }
    if rsa_body.len() > 65_536 || aes_body.len() > 65_536 {
        return Err(AuthShapeError::Oversized);
    }
    let mut packet = bytes_field(1, rsa_body);
    packet.extend(bytes_field(2, aes_body));
    Ok(packet)
}

/// Syntactic second-factor code validation for an OFFLINE state machine.
pub fn validate_mock_sms(code: &str) -> Result<(), AuthShapeError> {
    if (4..=8).contains(&code.len()) && code.bytes().all(|b| b.is_ascii_digit()) {
        Ok(())
    } else {
        Err(AuthShapeError::InvalidCode)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MockSecondFactor {
    AwaitingChallenge,
    AwaitingCode { issued: u64, expires: u64 },
    Completed,
}

impl MockSecondFactor {
    pub fn challenge(self, now: u64, ttl: u64) -> Result<Self, AuthShapeError> {
        if self != Self::AwaitingChallenge || ttl == 0 || ttl > 600 {
            return Err(AuthShapeError::InvalidCode);
        }
        Ok(Self::AwaitingCode { issued: now, expires: now.saturating_add(ttl) })
    }
    pub fn verify(self, now: u64, code: &str) -> Result<Self, AuthShapeError> {
        let Self::AwaitingCode { issued, expires } = self else {
            return Err(AuthShapeError::InvalidCode);
        };
        if now < issued || now > expires {
            return Err(AuthShapeError::InvalidCode);
        }
        validate_mock_sms(code)?;
        Ok(Self::Completed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn two_field_envelope_has_correct_wire_tags() {
        let packet = synthetic_secmanualauth_frame(&[0x01], &[0x02, 0x03]).unwrap();
        assert_eq!(packet, vec![0x0a, 0x01, 0x01, 0x12, 0x02, 0x02, 0x03]);
    }
    #[test]
    fn rejects_missing_and_oversized_frame() {
        assert_eq!(synthetic_secmanualauth_frame(&[], &[1]), Err(AuthShapeError::Empty));
        assert_eq!(synthetic_secmanualauth_frame(&[2], &[]), Err(AuthShapeError::Empty));
        assert_eq!(synthetic_secmanualauth_frame(&vec![7; 65_537], &[2]), Err(AuthShapeError::Oversized));
    }
    #[test]
    fn mock_sms_requires_challenge_and_is_time_limited() {
        assert!(MockSecondFactor::AwaitingChallenge.verify(5, "123456").is_err());
        let state=MockSecondFactor::AwaitingChallenge.challenge(100, 90).unwrap();
        assert!(state.verify(191,"123456").is_err());
        assert!(state.verify(101,"12ab56").is_err());
        assert_eq!(state.verify(110,"123456").unwrap(),MockSecondFactor::Completed);
    }
    #[test]
    fn rejects_unbounded_ttl_and_out_of_range_codes() {
        assert!(MockSecondFactor::AwaitingChallenge.challenge(10,0).is_err());
        assert!(MockSecondFactor::AwaitingChallenge.challenge(10,900).is_err());
        assert!(validate_mock_sms("1").is_err());
        assert!(validate_mock_sms("123456789").is_err());
    }
}
