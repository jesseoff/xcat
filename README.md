# xcat
xcat is a simple mechanism for mass distributing big files on LANs. It was
developed for simultaneously imaging multiple embedded board's SSDs while on a
burnin rack in a way that allows them to cooperate amongst themselves to ease
the IT department burden. Hundreds of of boards being turned on all at once
where each one of them requests the same disk image file at the same time can
easily saturate network uplinks and NICs. As much as IT departments love to buy
and reside over more fancy equipment, this can be solved without budget hikes
via a one-line change to production shell scripts.

From something like:

```shell
tar xfzv some/nfs/dir/image.tar.gz
```

to

```shell
xcat some/nfs/dir/image.tar.gz | tar xfzv -
```

xcat clients begin by broadcasting a pathname and file offset on udp port 19023.
From that point, an xcatd server will initiate a TCP connection back to the
client and send it the requested 16MByte chunk + checksum, if it has it. If
another xcat client happens to have that chunk in RAM, it will also attempt to
connect to the broadcasting client. The original client accepts one (and only
one) incoming connection and then closes the listening port. In this way,
whomever is the fastest to react and establish the connection first wins and the
rest have their connections harmlessly refused. It is expected xcat clients keep
at least one of the previous 16MByte chunks in memory as it attempts to download
the next. In the case of a lot of boards being turned on en-masse and
simultaneously attempting to fetch the same file, the origin xcatd server and/or
network pipe eventually gets overloaded and a situation develops naturally for
peers on closer ethernet switches to beat the origin xcatd server in
establishing the first response TCP connection.

Note that the 16Mbyte TCP transfers are intended to be sent from RAM to RAM,
i.e. not streamed from server filesystem to client filesystem or block device.
The server only initiates a connection after it has completely read the chunk
and calculated the checksum. The client only starts broadcasting requests when
it has a 16MByte block of memory ready and waiting.

The embedded xcat client is a simple single portable xcat.c that only holds onto
and serves helpouts on the previous 16mbyte chunk it has downloaded. This keeps
memory usage compatible with embedded boards with limited RAM, while still
allowing reasonable probabilty of being able to contribute and helpout peers
during simultaneous download. To maximize scalability in light of this finite
sliding window of transiently cached chunks, it is in the systems interest for
all boards to start at the same moment and proceed at approximately the same
pace. If a single downloader gets too far behind or too far ahead of its peers,
the network loses the benefit of swarm caching. A typical way to accomplish this
is to first synchronize time via NTP, then have all boards pause before download
and synchronize continuation to the 0 second of the next minute. Since most
boards write their SSDs at the same rate, it is likely boards remain in lock
step throughout while consuming the stdout stream.
