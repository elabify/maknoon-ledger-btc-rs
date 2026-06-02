use std::sync::Arc;

use ledger_bitcoin_client::apdu::{APDUCommand, StatusWord};
use ledger_bitcoin_client::async_client::Transport as UpstreamTransport;

use crate::error::LedgerError;
use crate::transport::{Transport as ForeignTransport, TransportError};

/// Adapter that lets upstream `ledger_bitcoin_client` drive our
/// foreign-callback `Transport`. Upstream calls `exchange(&self,
/// command: &APDUCommand)` with a structured APDU; we encode it
/// to wire bytes, forward to the host platform's transport, then
/// translate the response back into upstream's `(StatusWord,
/// Vec<u8>)` tuple.
///
/// Wrapped in `Arc` because upstream's `BitcoinClient<T>` owns
/// `T` by value, but our `Transport` is itself an `Arc<dyn ...>`
/// so cloning is cheap.
pub(crate) struct ForeignTransportAdapter {
    inner: Arc<dyn ForeignTransport>,
}

impl ForeignTransportAdapter {
    pub(crate) fn new(inner: Arc<dyn ForeignTransport>) -> Self {
        Self { inner }
    }
}

#[async_trait::async_trait]
impl UpstreamTransport for ForeignTransportAdapter {
    type Error = TransportError;

    async fn exchange(&self, command: &APDUCommand) -> Result<(StatusWord, Vec<u8>), Self::Error> {
        let bytes = command.encode();
        let response = self.inner.exchange(bytes).await?;
        let sw = StatusWord::try_from(response.status_word).map_err(|_| TransportError::Io {
            reason: format!("unknown status word 0x{:04X}", response.status_word),
        })?;
        Ok((sw, response.data))
    }
}

/// Map upstream `BitcoinClientError` into our public `LedgerError`.
/// The status-word 0x6985 ("user denied") is special-cased to
/// `UserCanceled` so UI code can distinguish user choice from
/// device failures.
pub(crate) fn map_bitcoin_client_error(
    err: ledger_bitcoin_client::error::BitcoinClientError<TransportError>,
) -> LedgerError {
    use ledger_bitcoin_client::error::BitcoinClientError as E;
    match err {
        E::Transport(t) => LedgerError::Transport {
            reason: t.to_string(),
        },
        E::Device { command, status } => {
            if status == StatusWord::Deny {
                LedgerError::UserCanceled
            } else {
                LedgerError::DeviceRejected {
                    status_word: status as u16,
                    reason: format!("command 0x{command:02X}, status {status:?}"),
                }
            }
        }
        E::InvalidPsbt => LedgerError::InvalidPsbt {
            reason: "PSBT is structurally invalid for signing".into(),
        },
        E::Interpreter(e) => LedgerError::Protocol {
            reason: format!("client-command interpreter: {e:?}"),
        },
        E::UnexpectedResult { command, data } => LedgerError::Protocol {
            reason: format!(
                "unexpected device response for command 0x{command:02X} ({} bytes)",
                data.len()
            ),
        },
        E::ClientError(s) => LedgerError::Protocol { reason: s },
        E::InvalidResponse(s) => LedgerError::Protocol {
            reason: format!("invalid device response: {s}"),
        },
        E::UnsupportedAppVersion => LedgerError::Protocol {
            reason: "unsupported Bitcoin app version on device".into(),
        },
    }
}
