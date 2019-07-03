#!/usr/bin/env bash
#
# Upgrade and/or fix an EPUB file using the Bookalope cloud service. Read the code for details 🤓

# Talk to the production server by default, or use -b/--beta to switch servers.
APIHOST="https://bookflow.bookalope.net"
APITOKEN=""

# Parse the options and arguments of this script. We need to support the old version of
# `getopt` as well as the updated one. More info: https://github.com/jenstroeger/Bookalope/issues/6
getopt -T > /dev/null
GETOPT=$?
if [ $GETOPT -eq 4 ]; then

    OPTIONS=`getopt --quiet --options hbo:kt:a:i:p: --longoptions help,beta,token:,keep,title:,author:,isbn:,publisher: -- "$@"`
    if [ $? -ne 0 ]; then
        echo -e "Error parsing command line options, exiting"
        exit 1
    fi
    eval set -- "$OPTIONS"
else
    OPTIONS=`getopt hbo:kt:a:i:p: $* 2> /dev/null`
    if [ $? -ne 0 ]; then
        echo -e "Error parsing command line options, exiting"
        exit 1
    fi
    set -- $OPTIONS
fi
while true; do
    case "$1" in
    -h | --help)
        echo "Usage: $(basename $0) [OPTIONS] epub"
        echo -e "Upgrade and/or fix an EPUB file using the Bookalope cloud service.\n"
        echo "Options are:"
        if [ $GETOPT -eq 4 ]; then
            echo "  -h, --help           Print this help and exit."
            echo "  -b, --beta           Use Bookalope's Beta server instead of its production server."
            echo "  -o, --token          Use this authentication token."
            echo "  -k, --keep           Keep the Bookflow on the server, do not delete."
            echo "  -t, --title title    Set the ebook's metadata: title."
            echo "  -a, --author author  Set the ebook's metadata: author."
            echo "  -i, --isbn isbn      Set the ebook's metadata: ISBN number."
            echo "  -p, --publisher pub  Set the ebook's metadata: publisher."
        else
            echo "  -h            Print this help and exit."
            echo "  -b            Use Bookalope's Beta server instead of its production server."
            echo "  -o            Use this authentication token."
            echo "  -k            Keep the Bookflow on the server, do not delete."
            echo "  -t title      Set the ebook's metadata: title."
            echo "  -a author     Set the ebook's metadata: author."
            echo "  -i isbn       Set the ebook's metadata: ISBN number."
            echo "  -p publisher  Set the ebook's metadata: publisher."
        fi
        echo -e "\nNote that the metadata of the original EPUB file overrides the command line options."
        exit 0
        ;;
    -b | --beta)
        APIHOST="https://beta.bookalope.net"
        shift
        ;;
    -o | --token)
        APITOKEN="$2"
        if [[ ! $APITOKEN =~ ^[0-9a-fA-F]{32}$ ]]; then
            echo "Malformed Bookalope API token, exiting"
            exit 1
        fi
        shift 2
        ;;
    -k | --keep)
        KEEPBOOKFLOW=true
        shift
        ;;
    -t | --title)
        METATITLE="$2"
        shift 2
        ;;
    -a | --author)
        METAAUTHOR="$2"
        shift 2
        ;;
    -i | --isbn)
        METAISBN="$2"
        shift 2
        ;;
    -p | --publisher)
        METAPUBLISHER="$2"
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        echo -e "Error parsing command line options, exiting"
        exit 1
        ;;
    esac
done
if [ $# -ne 1 ]; then
    echo -e "No EPUB file specified, exiting"
    exit 1
fi

EBOOKFILE=$1
TMPDIR=$(mktemp -d)

# Make sure that the ebook file actually exists.
if [ ! -f "$EBOOKFILE" ]; then
    echo "Ebook file $EBOOKFILE does not exist, exiting"
    exit 1
fi

# Check that Python 3 is available.
if [ ! `builtin type -p python3` ]; then
    echo "This script requires Python 3 to be installed, exiting"
    exit 1
fi

# Confirm which Bookalope server is being used.
echo "Talking to Bookalope server $APIHOST"

# Separate path, filename, and extension of the document.
EBOOKPATH=$(dirname "$EBOOKFILE")
EBOOKNAME=$(basename "$EBOOKFILE")
EBOOKBASE="${EBOOKNAME%.*}"

# Wait for a given number of seconds while showing a spinner.
function wait() {
    local COUNT=$1
    while ((COUNT--)); do
        for SPIN in '-' '\' '|' '/'; do
            echo -en "Waiting for Bookflow to finish $SPIN \r"
            sleep 0.25
        done
    done
}

# Use httpie to talk to the Bookalope server.
if [ `builtin type -p http` ]; then

    # Check that the Bookalope token authenticates correctly with the server.
    if [ ! `http --headers --auth $APITOKEN: GET $APIHOST/api/profile | grep HTTP | cut -d ' ' -f 2` == "200" ]; then
        echo "Wrong Bookalope API token, exiting"
        exit 1
    fi

    # Create a new book, and use the book's initial bookflow.
    echo "Creating new Book..."
    read -r BOOKID BOOKFLOWID <<< `http --ignore-stdin --json --print=b --auth $APITOKEN: POST $APIHOST/api/books name="$EBOOKBASE" title="$METATITLE" author="$METAAUTHOR" isbn="$METAISBN" publisher="$METAPUBLISHER" | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['book']['id'], obj['book']['bookflows'][0]['id']);"`
    echo "Done, Book id=$BOOKID, Bookflow id=$BOOKFLOWID"

    # Upload the ebook file which automatically ingests its content and styling. Passing the `skip_analysis`
    # argument here tells Bookalope to ignore the AI-assisted semantic structuring of the ebook, and instead
    # carry through the ebook's visual styles (AKA WYSIWYG conversion). The result is a flat and unstructured
    # ebook, but it is at least a valid EPUB3 file. So make sure you know what you're doing here.
    echo "Uploading and ingesting ebook file: $EBOOKNAME"
    base64 "$EBOOKFILE" > "$TMPDIR/$EBOOKNAME.base64"
    http --ignore-stdin --json --print= --auth $APITOKEN: POST $APIHOST/api/bookflows/$BOOKFLOWID/files/document file=@"$TMPDIR/$EBOOKNAME.base64" filename="$EBOOKNAME" filetype=epub skip_analysis=true

    # Wait until the bookflow's step changes from 'processing' to 'convert', thus indicating that Bookalope
    # has finished noodling through the ebook.
    while true; do
        wait 5
        STEP=`http --ignore-stdin --json --print=b --auth $APITOKEN: GET $APIHOST/api/bookflows/$BOOKFLOWID | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['bookflow']['step']);"`
        if [ "$STEP" = "convert" ]; then
            echo "Waiting for Bookflow to finish, done!"
            break
        fi
        if [ "$STEP" = "processing_failed" ]; then
            echo "Bookalope failed to ingest the ebook, exiting"
            exit 1
        fi
    done

    # Convert the ingested ebook file to EPUB3 and download it.
    # Regarding < /dev/tty see: https://github.com/jakubroztocil/httpie/issues/150#issuecomment-21419373
    echo "Converting to EPUB3 format and downloading ebook file..."
    DOWNLOAD_URL=`http --auth $APITOKEN: POST $APIHOST/api/bookflows/$BOOKFLOWID/convert format=epub3 version=final < /dev/tty | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['download_url'])"`
    while true; do
        wait 5
        STATUS=`http --auth $APITOKEN: GET $DOWNLOAD_URL/status < /dev/tty | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['status']);"`
        case "$STATUS" in
        "processing")
            ;;
        "failed")
            echo "Bookalope failed to convert the ebook, exiting"
            exit 1
            ;;
        "ok")
            echo "Waiting for Bookflow to finish, done!"
            break
            ;;
        esac
    done
    http --download --ignore-stdin --print= --auth $APITOKEN: GET $DOWNLOAD_URL > /dev/tty
    mv $BOOKFLOWID.epub "${EBOOKFILE%.*}-$BOOKFLOWID.epub"
    echo "Saved converted ebook to file ${EBOOKFILE%.*}-$BOOKFLOWID.epub"

    # Either delete the Bookflow and its files or keep them.
    if [ "$KEEPBOOKFLOW" = true ]; then
        echo "You can continue working with your Bookflow by clicking: $APIHOST/bookflows/$BOOKFLOWID/convert"
    else
        echo "Deleting Book and Bookflow..."
        http --ignore-stdin --print= --auth $APITOKEN: DELETE $APIHOST/api/books/$BOOKID
    fi
    echo "Done"

else

    # Use curl to talk to the Bookalope server.
    if [ `builtin type -p curl` ]; then

        # Check that the Bookalope token authenticates correctly with the server.
        if [ ! `curl --silent --show-error --user $APITOKEN: --request GET -s -D - -o /dev/null $APIHOST/api/profile | grep HTTP | cut -d ' ' -f 2` == "200" ]; then
            echo "Wrong Bookalope API token, exiting"
            exit 1
        fi

        # Create a new book, and use the book's initial bookflow.
        echo "Creating new Book..."
        read -r BOOKID BOOKFLOWID <<< `curl --silent --show-error --user $APITOKEN: --header "Content-Type: application/json" --data "{\"name\":\"$EBOOKBASE\",\"title\":\"$METATITLE\",\"author\":\"$METAAUTHOR\",\"isbn\":\"$METAISBN\",\"publisher\":\"$METAPUBLISHER\"}" --request POST $APIHOST/api/books | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['book']['id'], obj['book']['bookflows'][0]['id']);"`
        echo "Done, Book id=$BOOKID, Bookflow id=$BOOKFLOWID"

        # Upload the ebook file which automatically ingests its content and styling. Passing the `skip_analysis`
        # argument here tells Bookalope to ignore the AI-assisted semantic structuring of the ebook, and instead
        # carry through the ebook's visual styles (AKA WYSIWYG conversion). The result is a flat and unstructured
        # ebook, but it is at least a valid EPUB3 file. So make sure you know what you're doing here.
        echo "Uploading and ingesting ebook file: $EBOOKNAME"
        echo '{"filetype":"epub", "filename":"'$EBOOKNAME'", "skip_analysis":"true", "file":"' > "$TMPDIR/$EBOOKNAME.json"
        base64 "$EBOOKFILE" >> "$TMPDIR/$EBOOKNAME.json"
        echo '"}' >> "$TMPDIR/$EBOOKNAME.json"
        curl --silent --show-error --user $APITOKEN: --header "Content-Type: application/json" --data @"$TMPDIR/$EBOOKNAME.json" --request POST $APIHOST/api/bookflows/$BOOKFLOWID/files/document

        # Wait until the bookflow's step changes from 'processing' to 'convert', thus indicating that Bookalope
        # has finished noodling through the ebook.
        while true; do
            wait 5
            STEP=`curl --silent --show-error --user $APITOKEN: --header "Content-Type: application/json" --request GET $APIHOST/api/bookflows/$BOOKFLOWID | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['bookflow']['step']);"`
            if [ "$STEP" = "convert" ]; then
                echo "Waiting for Bookflow to finish, done!"
                break
            fi
            if [ "$STEP" = "processing_failed" ]; then
                echo "Bookalope failed to ingest the ebook, exiting"
                exit 1
            fi
        done

        # Convert the ingested ebook file to EPUB3 and download it.
        # Regarding < /dev/tty see: https://github.com/jakubroztocil/httpie/issues/150#issuecomment-21419373
        echo "Converting to EPUB3 format and downloading ebook file..."
        DOWNLOAD_URL=`curl --silent --show-error --user $APITOKEN: --header "Content-Type: application/json" --data '{"format":"epub3", "version":"final"}' --request POST $APIHOST/api/bookflows/$BOOKFLOWID/convert < /dev/tty | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['download_url'])"`
        while true; do
            wait 5
            STATUS=`curl --silent --show-error --user $APITOKEN: --header "Content-Type: application/json" --request GET $DOWNLOAD_URL/status < /dev/tty | python3 -c "import json,sys;obj=json.load(sys.stdin);print(obj['status']);"`
            case "$STATUS" in
            "processing")
                ;;
            "failed")
                echo "Bookalope failed to convert the ebook, exiting"
                exit 1
                ;;
            "ok")
                echo "Waiting for Bookflow to finish, done!"
                break
                ;;
            esac
        done
        curl --silent --show-error --user $APITOKEN: --remote-name --remote-header-name --request GET $DOWNLOAD_URL > /dev/tty
        mv $BOOKFLOWID.epub "${EBOOKFILE%.*}-$BOOKFLOWID.epub"
        echo "Saved converted ebook to file ${EBOOKFILE%.*}-$BOOKFLOWID.epub"

        # Either delete the Bookflow and its files or keep them.
        if [ "$KEEPBOOKFLOW" = true ]; then
            echo "You can continue working with your Bookflow by clicking: $APIHOST/bookflows/$BOOKFLOWID/convert"
        else
            echo "Deleting Book and Bookflow..."
            curl --silent --show-error --user $APITOKEN: --request DELETE $APIHOST/api/books/$BOOKID
        fi
        echo "Done"

    else
        echo "Unable to find http or curl command, exiting"
        exit 1
    fi
fi
rm -fr $TMPDIR
exit 0
