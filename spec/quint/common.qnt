// Shared vocabulary for every protocol module. Keep this file small:
// a module that needs more defines it locally.
module common {
  import schema.* from "./schema"

  type UserId = str

  // Reply to the caller of a request. NoReply for environment steps and events.
  // Ok carries no data; modules that need reply data model it in their own state
  // or events (e.g. a `lastReplyData` var), so this type stays shared.
  type Reply = Ok | Failed(str) | NoReply

  pure def send(us: Set[UserId], e: a): Set[(UserId, a)] = us.map(u => (u, e))

  // The one element of a set that has at most one element; `default` if empty.
  pure def theOne(xs: Set[a], default: a): a = xs.fold(default, (_, x) => x)

  pure def mapRemove(m: k -> v, key: k): k -> v =
    m.keys().exclude(Set(key)).mapBy(x => m.get(x))

  // reasonsInSchema for a command: a Failed reply must use a reason that
  // command's response schema lists.
  pure def replyInSchema(cmd: str, r: Reply): bool = match r {
    | Failed(reason) => reasonAllowed(cmd, reason)
    | Ok => true
    | NoReply => true
  }
}
