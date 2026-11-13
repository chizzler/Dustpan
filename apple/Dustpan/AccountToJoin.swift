import DustpanCore

/// An account the server vouched for, waiting for the choice of what to do with another account's data here.
struct AccountToJoin {
    let config: Config
    let userId: String
    let key: JSON?
}
