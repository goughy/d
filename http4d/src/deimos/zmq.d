/*
    Copyright (c) 2007-2010 iMatix Corporation

    This file is part of 0MQ.

    0MQ is free software; you can redistribute it and/or modify it under
    the terms of the GNU Lesser General Public License as published by
    the Free Software Foundation; either version 3 of the License, or
    (at your option) any later version.

    0MQ is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/
module zmq;


extern (C)
{

/******************************************************************************/
/*  0MQ versioning support.                                                   */
/******************************************************************************/

/*  Version macros for compile-time API version detection                     */

enum
{
    ZMQ_VERSION_MAJOR   =3,
    ZMQ_VERSION_MINOR   =2,
    ZMQ_VERSION_PATCH   =2
}

/*  Run-time API version detection                                            */
void zmq_version(int* major, int* minor, int* patch);

/******************************************************************************/
/*  0MQ errors.                                                               */
/******************************************************************************/

/*  A number random anough not to collide with different errno ranges on      */
/*  different OSes. The assumption is that error_t is at least 32-bit type.   */
immutable enum
{
    ZMQ_HAUSNUMERO = 156384712,

/*  On Windows platform some of the standard POSIX errnos are not defined.    */
    ENOTSUP         = (ZMQ_HAUSNUMERO + 1),
    EPROTONOSUPPORT = (ZMQ_HAUSNUMERO + 2),
    ENOBUFS         = (ZMQ_HAUSNUMERO + 3),
    ENETDOWN        = (ZMQ_HAUSNUMERO + 4),
    EADDRINUSE      = (ZMQ_HAUSNUMERO + 5),
    EADDRNOTAVAIL   = (ZMQ_HAUSNUMERO + 6),
    ECONNREFUSED    = (ZMQ_HAUSNUMERO + 7),
    EINPROGRESS     = (ZMQ_HAUSNUMERO + 8),
    ENOTSOCK        = (ZMQ_HAUSNUMERO + 9),
    EMSGSIZE        = (ZMQ_HAUSNUMERO + 10),
    EAFNOSUPPORT    = (ZMQ_HAUSNUMERO + 11),
    ENETUNREACH     = (ZMQ_HAUSNUMERO + 12),
    ECONNABORTED    = (ZMQ_HAUSNUMERO + 13),
    ECONNRESET      = (ZMQ_HAUSNUMERO + 14),
    ENOTCONN        = (ZMQ_HAUSNUMERO + 15),
    ETIMEDOUT       = (ZMQ_HAUSNUMERO + 16),
    EHOSTUNREACH    = (ZMQ_HAUSNUMERO + 17),
    ENETRESET       = (ZMQ_HAUSNUMERO + 18),

/*  Native 0MQ error codes.                                                   */
    EFSM            = (ZMQ_HAUSNUMERO + 51),
    ENOCOMPATPROTO  = (ZMQ_HAUSNUMERO + 52),
    ETERM           = (ZMQ_HAUSNUMERO + 53),
    EMTHREAD        = (ZMQ_HAUSNUMERO + 54)
}//enum error_code

/*  This function retrieves the errno as it is known to 0MQ library. The goal */
/*  of this function is to make the code 100% portable, including where 0MQ   */
/*  compiled with certain CRT library (on Windows) is linked to an            */
/*  application that uses different CRT library.                              */
int zmq_errno();

/*  Resolves system errors and 0MQ errors to human-readable string.           */
char* zmq_strerror(int errnum);

/******************************************************************************/
/*  0MQ message definition.                                                   */
/******************************************************************************/
immutable enum
{
/*  Maximal size of "Very Small Message". VSMs are passed by value            */
/*  to avoid excessive memory allocation/deallocation.                        */
/*  If VMSs larger than 255 bytes are required, type of 'vsm_size'            */
/*  field in zmq_msg_t structure should be modified accordingly.              */
    ZMQ_MAX_VSM_SIZE    = 32,

/*  Message types. These integers may be stored in 'content' member of the    */
/*  message instead of regular pointer to the data.                           */
    ZMQ_DELIMITER       = 31,
    ZMQ_VSM             = 32,

/*  Message flags. ZMQ_MSG_SHARED is strictly speaking not a message flag     */
/*  (it has no equivalent in the wire format), however, making  it a flag     */
/*  allows us to pack the stucture tigher and thus improve performance.       */
    ZMQ_MSG_MORE        = 1,
    ZMQ_MSG_SHARED      = 128,
    ZMQ_MSG_MASK        = 129
}

/*  A message. Note that 'content' is not a pointer to the raw data.          */
/*  Rather it is pointer to zmq::msg_content_t structure                      */
/*  (see src/msg_content.hpp for its definition).                             */
struct zmq_msg_t
{
    ubyte x[ZMQ_MAX_VSM_SIZE];
}

int zmq_msg_init(zmq_msg_t* msg);
int zmq_msg_init_size(zmq_msg_t* msg, size_t size);
int zmq_msg_init_data(zmq_msg_t* msg, void* data,
    size_t size, void function(void* data, void* hint), void* hint);
int zmq_msg_close(zmq_msg_t* msg);
int zmq_msg_move(zmq_msg_t* dest, zmq_msg_t* src);
int zmq_msg_copy(zmq_msg_t* dest, zmq_msg_t* src);
void* zmq_msg_data(zmq_msg_t* msg);
size_t zmq_msg_size(zmq_msg_t* msg);
int zmq_msg_send(zmq_msg_t *msg, void *socket, int flags);
int zmq_msg_recv (zmq_msg_t *msg, void *socket, int flags);

/******************************************************************************/
/*  0MQ infrastructure (a.k.a. context) initialisation & termination.         */
/******************************************************************************/

void *zmq_ctx_new();
int zmq_ctx_destroy(void *context);
int zmq_ctx_set(void *context, int option, int optval);
int zmq_ctx_get(void *context, int option);

/******************************************************************************/
/*  0MQ socket definition.                                                    */
/******************************************************************************/

/*  Socket types.                                                             */
immutable enum
{
    ZMQ_PAIR        = 0,
    ZMQ_PUB         = 1,
    ZMQ_SUB         = 2,
    ZMQ_REQ         = 3,
    ZMQ_REP         = 4,
    ZMQ_DEALER      = 5,
    ZMQ_ROUTER      = 6,
    ZMQ_PULL        = 7,
    ZMQ_PUSH        = 8,
    ZMQ_XPUB        = 9,
    ZMQ_XSUB        = 10
}

/*  Socket options.                                                           */
immutable enum
{
    ZMQ_AFFINITY        = 4,
    ZMQ_IDENTITY        = 5,
    ZMQ_SUBSCRIBE       = 6,
    ZMQ_UNSUBSCRIBE     = 7,
    ZMQ_RATE            = 8,
    ZMQ_RECOVERY_IVL    = 9,
    ZMQ_SNDBUF          = 11,
    ZMQ_RCVBUF          = 12,
    ZMQ_RCVMORE         = 13,
    ZMQ_FD              = 14,
    ZMQ_EVENTS          = 15,
    ZMQ_TYPE            = 16,
    ZMQ_LINGER          = 17,
    ZMQ_RECONNECT_IVL   = 18,
    ZMQ_BACKLOG         = 19,
    ZMQ_RECONNECT_IVL_MAX = 21,
    ZMQ_MAXMSGSIZE      = 22,
    ZMQ_SNDHWM          = 23,
    ZMQ_RCVHWM = 24,
    ZMQ_MULTICAST_HOPS = 25,
    ZMQ_RCVTIMEO = 27,
    ZMQ_SNDTIMEO = 28,
    ZMQ_IPV4ONLY = 31,
    ZMQ_LAST_ENDPOINT = 32,
    ZMQ_ROUTER_MANDATORY = 33,
    ZMQ_TCP_KEEPALIVE = 34,
    ZMQ_TCP_KEEPALIVE_CNT = 35,
    ZMQ_TCP_KEEPALIVE_IDLE = 36,
    ZMQ_TCP_KEEPALIVE_INTVL = 37,
    ZMQ_TCP_ACCEPT_FILTER = 38,
    ZMQ_DELAY_ATTACH_ON_CONNECT = 39,
    ZMQ_XPUB_VERBOSE = 40
}
/* Message options                                                           */
immutable enum
{
    ZMQ_MORE = 1
}

/*  Send/recv options.                                                        */
immutable enum
{
    ZMQ_DONTWAIT = 1,
    ZMQ_SNDMORE = 2
}

void* zmq_socket(void* context, int type);
int zmq_close(void* s);
int zmq_setsockopt(void* s, int option, void* optval, size_t optvallen);
int zmq_getsockopt(void* s, int option, void* optval, size_t *optvallen);
int zmq_bind(void* s, const char* addr);
int zmq_connect(void* s, immutable char* addr);
int zmq_unbind(void *s, const char *addr);
int zmq_disconnect(void *s, const char *addr);
int zmq_sendmsg(void* s, zmq_msg_t* msg, int flags);
int zmq_recvmsg(void* s, zmq_msg_t* msg, int flags);

/******************************************************************************/
/*  I/O multiplexing.                                                         */
/******************************************************************************/

immutable enum
{
    ZMQ_POLLIN  = 1,
    ZMQ_POLLOUT = 2,
    ZMQ_POLLERR = 4
}

__gshared struct zmq_pollitem_t
{
    void* socket;
    version (win32)
    {
        SOCKET fd;
    }
    else
    {
        int fd;
    }
    short events;
    short revents;
}

int zmq_poll(zmq_pollitem_t* items, int nitems, long timeout);

/******************************************************************************/
/*  Built-in devices                                                */
/******************************************************************************/

immutable enum
{
    ZMQ_STREAMER     = 1,
    ZMQ_FORWARDER    = 2,
    ZMQ_QUEUE        = 3
}

int zmq_device(int device, void* insocket, void* outsocket);

}// extern (C)
