# TCP Flow Control, Congestion Control

To ensure reliable communication, neither the receiver, nor the network can be overwhelmed during a transfer. To ensure this, TCP relies on two main mechanisms:
1. **Flow Control:** Protects the *receiver* from being overwhelmed
	1. The receiver advertises a *Receive Window* `rwnd`. This is the amount of data the receiver can accept (free space in its receive buffer).
2. **Congestion Control:** Protects the *network* from being overwhelmed
	1. The sender makes an estimate of the networks capacity and calculates a *Congestion Window* `cwnd`. 
	2. This window can be increased to see if the network can handle more throughput. When packet loss is detected (indicating congestion), `cwnd` is shrunk.

The actual amount of data a sender is allowed to put "in flight" over the network is always the minimum of these two values: **$Window = \min(rwnd, cwnd)$**.

Once the window has been filled, the sender has to stop and wait for acknowledgements (ACKs) from the receiver before sending additional data. This means that **$Throughput_{max} = \frac{Window}{RTT}$**. As was said, the Window dictates how much data the sender can put in flight at once, and round trip time tells us how long that data takes to arrive to the receiver + the time it takes for the ACKs to arrive back to the sender. 

This is the key to most things touched upon in this lab. If the windows is too small, the sender cannot saturate the link.

## Bandwidth-Delay Product (BDP)

The amount of data in flight that saturates the link is called the **Bandwidth-Delay Product** and is calculated as:
**$BDP = Bandwidth \times RTT$**

To calculate the BDP in bytes, bandwidth should be plugged into the formula in bits per second, RTT in seconds and the whole thing be divided by 8.

*Example:* The BDP for a 100 Mbps link with an RTT of 50 ms would be calculated as `100,000,000 × 0.05 / 8 = 625,000 B`. To saturate the whole 100 Mbps link, you need a window of at least 625 KB. With a window of only 64 KB (the default max value without scaling) it could reach at most `64,000 × 8 / 0.05 ≈ 10 Mbps`, wasting 90 % of the links capability.

Networks with a large BDP are called Long Fat Networks (LFNs). These are typically networks where old congestion control algorithms and default TCP settings have problems achieving maximum throughput.

## Flow Control in Linux

### The 16-bit Window and Window Scaling

The window field in a TCP header is 16 bits long. This means that the highest number it can hold is **65,535 bytes**. This was fine in the past, but as you could see in the example calculation above, this would cap the speed at about 10 Mbps.

To fix this, we can use **Window Scaling**:
- While performing the handshake, both sides announce their own **shift count** (`wscale`) in the SYN and SYN-ACK packet. 
- This value is then used to multiply the window value in every header after the handshake by $2^{shift}$. 
- The shift can have a maximum value of 14, allowing for windows of up to 1 GiB.
- It is only used if both sides have it enabled (they both announce it during the handshake). If one has this option disabled, the maximum window stays at the original 65,535 bytes.

### Socket Buffers: `tcp_rmem` and `tcp_wmem`

The kernel gives two buffers to each TCP connection:

- **Receive buffer**
	- Holds data that has been received but not yet read by the application.
	- The advertised `rwnd` is derived from the free space inside this buffer (explained in more detail below).
- **Send buffer**
	- Holds data that the application has sent, but that have not yet been acknowledged.
	- This limits the sender's amount of data in flight.

They are controlled by two kernel parameters, `tcp_rmem` and `tcp_wmem`. Each has three values (in bytes): `"min default max"`. A new connection starts with the _default_ size, and Linux can grow the buffer up to _max_ as the connection needs it:
- The **send buffer** always grows automatically.
- The **receive buffer** grows only if `net.ipv4.tcp_moderate_rcvbuf` is `1`. Otherwise it stays at the _default_ size.

When setting these values, we have to keep in mind that data being written to the buffers is not just the raw payload. There has to be some metadata. This means we have to set the buffer to be larger to fit both the payload and its metadata. This is why buffers are usually set to roughly **twice the BDP**. 

## Congestion Control
### Slow Start

To avoid congesting the link right from the start, the `cwnd` size starts at the **Initial Window**. On Linux, this is **10 segments**. A segment can carry up to one **MSS** (Maximum Segment Size) of data (which is 1448 bytes here).  For every acknowledged segment, `cwnd` grows by one segment -> it doubles every RTT (first sends 10 segments, receives 10 ACKs, increases `cwnd` by 10, sends 20 segments, receives 20 ACKs...)

Slow start ends when a loss is detected, or when a threshold is reached. The connection then switches to **congestion avoidance** and the window start growing much slower.

### Loss-Based Algorithms: Reno and CUBIC

**TCP Reno:**
- Uses **AIMD** (Additive Increase, Multiplicative Decrease)
	- In congestion avoidance, it adds only **1 segment per RTT** to the value of `cwnd`. 
	- When a packet is lost, it assumes it was due to congestion and **halves** the value of `cwnd`.
- Cannot tell the difference between random packet loss and congestion -> very slow in the presence of packet loss, because it decreases the window faster than it can grow it back up.
- The throughput can be estimated by the **Mathis formula**:
	- **$Throughput \approx \frac{MSS}{RTT} \times \frac{1.22}{\sqrt{p}}$**, where $p$ represents random loss rate
**CUBIC:**
- The Linux default since 2006.
- Reduces `cwnd` to 70 % after a loss instead of 50 %.
- Grows the window along a cubic curve.
	- Quickly at first, slows down when it approaches the size where loss last happened, then quickly again to probe way beyond that value.
- It recovers much faster than Reno on links with a high BDP, but every random loss still makes it decrease the window significantly.

### Model-based Algorithms: BBR

Instead of reacting to losses, BBR (Bottleneck Bandwidth and Round-trip propagation time) uses two metrics to decide how fast to send data and how much to keep in flight. 
- **Highest delivery rate** it has recently seen (how much data the receiver confirmed in some window of time). 
- **Lowest RTT** recently encountered. 
It builds a model of the link using these two metrics and uses it to estimate a bottleneck speed. Data is sent at this estimated rate and the algorithm keeps roughly one BDP of data in flight. The used metrics aren't affected much by random loss. This means that it is able to perform much better on lossy links, where loss-based algorithms fail.

One drawback is that it can take up a big part of the bandwidth of a link, so other CUBIC flows sharing this link can be bottlenecked by it. But if you are doing only a single transfer over a lossy link, it becomes less of a problem.

### Pacing and the `fq` Queueing Discipline

Loss-based algorithms wait for ACKs to come from the receiver. When they receive an ACK, they immediately send out data to fill the window. This means that they usually send in bursts, and then wait for that window to be confirmed. BBR tries to space packets out evenly at the estimated bottleneck rate. This is called **pacing**.

In Linux, packets leaving an interface pass through a **queueing discipline** (qdisc). This is manages using the `tc` command. The `fq` (Fair Queue) queueing discipline implements per-flow pacing. It is the recommended companion for BBR.

---

Congestion control runs **only on the sender**. The way the receiver's congestion control is set up is irrelevant for a transfer in the other direction. In this lab, the client downloads from a server (the server is the sender). So we will be configuring the congestion control algorithm and qdisc on the server.

---
## Starting the Lab Environment

This lab runs in **GitHub Codespaces**: a Linux machine in the cloud that you use from your browser. It uses **Kathará**, a container-based network emulation tool, to run the three devices of the lab.

1. Open the assignment repository: **[TCP_lab](https://github.com/Ptic360/TCP_lab.git)**
2. Click the green **Code** button → **Codespaces** tab → **Create codespace on main**. The default 2-core machine is enough.
3. The first start takes a few minutes while Kathará is installed. Wait until the terminal at the bottom of the window is ready.
4. Start the lab:

```bash
sudo ./start_lab
```

Upon running the script, you will be prompted for your **6-digit Student ID**. The script then boots the devices and prints the lab instructions with all the values you need.

Codespaces are free within a monthly allowance (about 60 hours per month on a 2-core machine for a free GitHub account), which is far more than this lab needs. When you take a break or finish, **stop the Codespace** (see the end of this document) so it does not keep using your allowance.

If you run into problems with the environment, reset the Kathará scenario and start again:

```bash
sudo kathara lclean -d tcp_lab
sudo ./start_lab
```

If you prefer not being handed all the commands to finish the lab, you can skip reading the walkthrough section and finish the lab using only the instructions printed into the CLI.

---
## Lab Walkthrough: Tuning TCP

In this scenario, a `client` downloads data from a `server` across a WAN, emulated by a `router` in the middle:

```
client (10.0.1.2) ---- router (WAN) ---- server (10.0.2.2)
```

The router emulates a long-distance path:

- **Bandwidth:** 20 Mbps towards the client
- **RTT:** 80 ms (40 ms in each direction)
- **Random packet loss:** 0.1 % on the way to the client

**Do not modify the router.** The autograder checks it, and the lab will not pass if its settings change.

It is highly recommended that you write down the commands you used into a separate `.txt` file. Restarting the lab resets all settings, so this makes it easier to redo the exercise.

### Accessing the Devices

Connect to the client or the server from the Codespace terminal:

```bash
sudo kathara connect -d tcp_lab client
sudo kathara connect -d tcp_lab server
```

Inside the devices you are `root`, so no `sudo` is needed there. Type `exit` to get back to the Codespace terminal.

### Setting Correct Values for Flow & Congestion Control 

**Task 0: Measure the baseline download speed on the client:**

```bash
iperf3 -c 10.0.2.2 -R
```

The `-R` flag is used to start a reverse transfer (from the server to the client). Note the result. 

To get more information about what is going on behind the scenes, run `ss -tin dst 10.0.1.2` on the **server** in a second terminal during a longer test (add `-t 30` to the iperf command). You will see two connections. The one with a large `bytes_sent` carries the download; the other is iperf’s control connection. Look at `wscale` (is it present, or missing?), `cwnd` (in segments), `snd_wnd` (the `rwnd` the client advertised, already in bytes), and the congestion control algorithm. 

The link can carry 20 Mbps, but the download only reaches a few. Compare the result with $$Throughput\approx\frac{min(rwnd, cwnd \times MSS)}{RTT} \rightarrow \frac{Window}{RTT}$$Neither endpoint can keep more than a few tens of kilobytes in flight. You can also see the `unacked` count. If you multiply it by `MSS` (`ss` outputs it in bytes), you should get the size of the `snd_wnd`.

**Task 1: Calculate the BDP in bytes:** Use the values from the start of the walkthrough. $$BDP = Bandwidth[bps] \times RTT [s]$$Don't forget to convert this number into **bytes** and write it alone (no units, no other text) into `/root/bdp.txt` on the **client**:

```bash
echo <YOUR_BDP> > /root/bdp.txt
```

**Task 2: Flow Control on the Receiver (Client):**
Use `sysctl -w` to change these values:
- Enable window scaling: `net.ipv4.tcp_window_scaling=1`
- Enable receive buffer autotuning: `net.ipv4.tcp_moderate_rcvbuf=1`
- Raise the **max** value of `net.ipv4.tcp_rmem` to at least $2\times BDP$ (e.g. $2.5\times$ should suffice)
	- Keep the _min_ and *default* values the same (you can check the current values using `sysctl net.ipv4.tcp_rmem`).
	- Syntax: `sysctl -w "net.ipv4.tcp_rmem=min default max"`

*Note: Using `sysctl -w` makes these changes only temporarily, if you were doing this in a real deployment, you would add these parameters to /etc/sysctl.conf*

The client can now advertise a window larger than 65,535 bytes, and its receive buffer can grow large enough to hold a whole BDP of data. The receiver is no longer the bottleneck.

**Task 3: Flow Control on the Sender:**
On the server:
- Enable window scaling. Scaling only works if _both_ sides enable it.
- Raise the **max** value of `net.ipv4.tcp_wmem` to at least **2× BDP**.

Measure again from the client. The result should be noticeably better, but still far from 20 Mbps. Compare algorithms on the same settings by choosing them for a single test:

```bash
iperf3 -c 10.0.2.2 -R -C reno
iperf3 -c 10.0.2.2 -R -C cubic
```

Both windows are now large enough, so flow control is no longer the limit. What limits the connection now is congestion control: every random loss makes the server back off, and on this path it cannot grow back fast enough. Plug the lab's values into the Mathis formula: $$Throughput \approx \frac{MSS[bits]}{RTT[s]} \times \frac{1.22}{\sqrt{p}}$$and compare the estimate with your measurement. CUBIC is usually somewhat better than Reno, but it still held back by being loss-based (if you run it multiple times, you can see it start fast and quickly decline after a few losses).

**Task 4: Congestion Control (Server)** 
On the **server**:
- Make **BBR** the default congestion control algorithm using `net.ipv4.tcp_congestion_control`
- Replace the qdisc on `eth0` with **`fq`** to enable pacing.
	- You can view the current qdisc using `tc qdisc show dev <INTERFACE>`
	- Replace the current one using `tc qdisc replace dev <INTERFACE> root <QDISC>`

Measure again from the client, this time without `-C`, so the server's default algorithm is used. BBR treats the random losses as what they are and sends at the measured bottleneck rate. The download should now come close to the full 20 Mbps and be more consistent in its speed.

A single download must reach at least **15 Mbps**. The autograder measures this with its own `iperf3` test using the server's default algorithm, so selecting BBR only with `-C` in your own tests is not enough.

### Validate and Grade

Once you have completed all tasks, type `exit` until you are back in the Codespace terminal, and run the autograder:

```bash
sudo ./grade_lab
```

The autograder checks the settings on both endpoints, verifies that the router is unchanged, checks your BDP answer file, and then measures the download speed. This can take up to a minute.

If all checks pass, the environment tears itself down and you receive a unique submission token. If something fails, the autograder lists every failed check and keeps the lab running, so you can reconnect, fix the problem and run `sudo ./grade_lab` again.

### Submit your unique string to IS

If your configuration passed the autograder successfully, you will get a string made up of your ID and a unique hash (e.g., `123456-abcdef123456`).

Make a text file named `hw04.txt` and paste this string into it. Do not include any other characters, spaces, or new lines. After saving, submit the text file with your unique string into the IS to receive your points.

### Manual Cleanup

If you make a catastrophic mistake and wish to completely reset the lab environment from scratch, tear down the Kathará scenario and start again:

```bash
sudo kathara lclean -d tcp_lab
sudo ./start_lab
```

## Stopping the Codespace

A running Codespace uses your monthly allowance even when you are not working in it. It stops automatically after 30 minutes of inactivity, but it is better to stop it yourself:

- Inside the Codespace, press **Ctrl+Shift+P** and run **Codespaces: Stop Current Codespace**, or
- Go to **github.com/codespaces**, click **⋯** next to your Codespace and choose **Stop codespace**.

A stopped Codespace keeps your files, and you can restart it from the same page. Once you have submitted your token, you should delete the Codespace there as well.