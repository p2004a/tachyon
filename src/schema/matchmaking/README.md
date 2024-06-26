The matchmaking cycle works as follows:

1. Clients should first retrieve a list of all the available queues from the server using [list](#list).
2. Clients should then queue for one or more of these queues by sending an array of the queue ids in a [queue](#queue) request.
3. The server can send periodic updates about the status of the search as a [queueUpdate](#queueupdate) event.
4. When a match is found, the server should send a [found](#found) event along with the id of the queue of the found match.
5. Clients can then ready up by sending a [ready](#ready) request. The number of readied players should be sent to clients via the [readyUpdate](#readyupdate) event.
6. To cancel queueing, or to decline a found match, clients should send a [cancel](#cancel) request.
7. If a client fails to ready up for a found match, the server should send a [lost](#lost) event, and the queueing phase should resume.
8. Once all players are ready, the server should send a [autohost/battleStart](#autohost/battleStart) request to a suitable autohost client. If the autohost doesn't respond quickly, or if it sends a failed response, the server should repeat this step.
9. Once the autohost has successfully started the battle, the server should then send [battle/battleStart](#battle/battleStart) requests to the users.