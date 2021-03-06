module GTL.SVG (
  gtlToSvg,
  svgHeader,
  svgFooter,
  threadHeight,
  imageWidth,
  detailsWidth,
  svgIndent,
  svgSpace,
  Px   (..),
  Point(..)
  ) where

import Data.Tree
import qualified Data.Map as Map
import Control.Monad.State
import Control.Applicative
import Text.Printf (printf)
import Data.List (elemIndices, (\\), partition, sort, intercalate, foldl')
import Data.Char (ord)

import GTL.Parser

--import Debug.Trace

type Px = Float
type Point = (Px, Px)

threadHeight  = 15 :: Px
imageWidth    = 1000 :: Px
detailsWidth  = 350
svgIndent     = 10 :: Px
svgSpace      = 1 :: Px

findLastTs :: Integer -> MyTree -> Integer
findLastTs curMax tree = newMax
  where
    (_, _, _, rs) = rootLabel tree
    trees = subForest tree
    BRecord { rTime = s, rDur = d } = last rs
    curEnd = s + fromIntegral d
    otherEnds = map (findLastTs curMax) trees
    newMax = maximum (curMax:curEnd:otherEnds)


data SData = SData {
    nesting  :: Int      -- nesting level
  }
type MyState = State SData

shiftTs globalTs (startTs, dur, pid, rs) = (startTs - globalTs, dur, pid, rs')
  where
    rs' = flip map rs $ \r -> r { rTime = rTime r - globalTs }

gtlToSvg :: MyTree -> [String]
gtlToSvg tree' = svgHeader ++ repr ++ svgFooter
  where
    (startTs, _, _, _) = rootLabel tree'
    tree = fmap (shiftTs startTs) tree'
    (_, _, _, seq) = rootLabel tree

    startState  = SData { nesting  = 0 }
    (_, nodeRepr) = evalState (drawNode tree True) startState
    repr = ["<script>"]
        ++ ["    var treeRoot = "]
        ++ nodeRepr
        ++ ["</script>", ""]


drawNode :: MyTree -> Bool -> MyState (Integer, [String])
drawNode tree root = do
    st@SData { nesting  = nesting } <- get
    let (curTs,_,pid,seq) = rootLabel tree
    let childs = subForest tree
    let spaces = replicate (4 * nesting) ' '
    put st { nesting = nesting + 1 }
    (lastTs, childNodes) <- unzip <$> mapM (flip drawNode False) childs
    let childRepr = concat childNodes
    let curFinish = rTime (last seq) + fromIntegral ( rDur (last seq) )
    let finish = maximum $ curFinish:lastTs
    let dur = finish - curTs
    let sumDur = fromIntegral $ finish - 0 -- as startTs is always 0
    let nodeArgs = "(" ++ show dur ++ ", " ++ drawSeq seq sumDur ++ ")"
    let nodeRepr = case root of
          True  -> [spaces ++ "new TreeNode" ++ nodeArgs] ++ childRepr
          False -> [spaces ++ ".appendChild" ++ nodeArgs] ++ childRepr ++ [spaces ++ ".parent"]
    put st { nesting = nesting }
    return (finish, nodeRepr)

drawSeq :: [BRecord] -> Int -> String
drawSeq rs dur =
  "[" ++ intercalate ", " (map (drawMFA dur) rs) ++ "]"

drawMFA :: Int -> BRecord -> String
drawMFA dur r = "new MFA("
    ++ "\"" ++ safeXML (rNode r)        ++ "\", "
    ++ "\"" ++ safeXML (rPid r)         ++ "\", "
    ++ "\"" ++ safeXML (rModule r)      ++ "\", "
    ++ "\"" ++ safeXML (rFunction r)    ++ "\", "
    ++ "\"" ++ safeXML (rArg r)         ++ "\", "
    ++ ""   ++ show (rTime r)           ++ ", "
    ++ ""   ++ show tf                  ++ ", "
    ++ ""   ++ show (rDur r)            ++ ", "
    ++ "\"" ++ percent (rDur r) dur     ++ "\", "
    ++ "\"" ++ color                    ++ "\")"
  where
    tf = (rTime r + fromIntegral (rDur r))
    color = colorMFA(rModule r, rFunction r, rArg r) colorScheme2

type Color = String
type ColorScheme = [Color]

-- color for module
colorScheme2 :: ColorScheme
colorScheme2 = [
    -- http://colorschemedesigner.com/#5B42kw0w0w0w0
    "#FB000D", "#A30008",
    "#FFA400", "#BF8C30", "#A66B00",
    "#1049A9", "#052C6E", "#6A92D4",
    "#14D100", "#329D27", "#0D8800",
    -- yellows
    "#999900", "#BBBB22", "#DDDD00", "#FFFF00", "#FFFFBB",
    -- grays
    "#000000", "#666666", "#999999", "#BBBBBB",
    -- blues
    "#14D1FF",
    -- green
    "#AAFFAA",
    -- pink
    "#FFA4AA", "#FF64AA" ]

printScheme :: ColorScheme -> String
printScheme scheme = "<svg height=1000 width=100>" ++ rects ++ "</svg>"
  where
    rects = concat [
      "<rect"
      ++ " x=0"
      ++ " y=" ++ show (ix*16)
      ++ " width=100"
      ++ " height=15"
      ++ " fill=" ++ c
      ++ " />" |  c  <- colorScheme2,
                  ix <- elemIndices c colorScheme2]

colorMFA :: (String, String, String) -> ColorScheme -> Color
colorMFA (m, _, _) scheme = scheme !! idx
  where
    idx = sumletters m `mod` length scheme

sumletters = sum . (map ord)

percent :: Int -> Int -> String
percent a b = printf "%.3f%%" $ 100 * (fromIntegral a
                                     / fromIntegral b :: Percent)

safeXML :: String -> String
safeXML p = reverse $ foldl' safeXml' [] p
  where
    safeXml' acc '<'  = reverse "&lt;" ++ acc
    safeXml' acc '>'  = reverse "&gt;" ++ acc
    safeXml' acc '"'  = reverse "&quot;" ++ acc
    safeXml' acc '\'' = {- TODO: reverse "&apos;" ++-} acc
    safeXml' acc '&'  = reverse "&amp;" ++ acc
    safeXml' acc c    = c:acc


svgHeader = [
  "<html xmlns=\"http://www.w3.org/1999/xhtml\"> ",
  "<body onload=\"init()\">  ",
  "",
  "<script type=\"text/javascript\">",
  "    var curRoot;",
  "    var captionHeight = 40; var scaleHeight = 25;",
  "    var minWidth = 5;",
  "    var rectHeight = 15;",
  "    var detailsPopup;",
  "    var detailsM, detailsF, detailsA, detailsNode, detailsPid, detailsTs, detailsDur, detailsPc;",
  "    var graph, svg_width, svg_height;",
  "    function init() {",
  "        detailsPopup = document.getElementById(\"detailsPopup\");",
  "        detailsNode = document.getElementById(\"node\");",
  "        detailsPid = document.getElementById(\"pid\");",
  "        detailsM = document.getElementById(\"m\");",
  "        detailsF = document.getElementById(\"f\");",
  "        detailsA = document.getElementById(\"a\");",
  "        detailsTs = document.getElementById(\"ts\");",
  "        detailsDur = document.getElementById(\"dur\");",
  "        detailsPc = document.getElementById(\"pc\");",
  "        graph = document.getElementById(\"graph\");",
  "        svg_width = document.getElementById(\"svg_outer\").width.baseVal.value;",
  "        svg_height = document.getElementById(\"svg_outer\").height.baseVal.value;",
  "        document.getElementsByName(\"minWidth\")[0].value = minWidth;",
  "        document.getElementsByName(\"rectHeight\")[0].value = rectHeight;",
  "        redrawSVG();",
  "    }",
  "    function s(evt, node, pid, m, f, a, ts, dur, pc) {",
  "        detailsPopup.style.left = evt.clientX + 10;",
  "        detailsPopup.style.visibility = \"hidden\";",
  "        detailsPopup.style.display = \"block\";",
  "        var top = evt.clientY + 20;",
  "        detailsPid.innerHTML = pid;",
  "        detailsNode.innerHTML = node;",
  "        detailsM.innerHTML = m;",
  "        detailsF.innerHTML = f;",
  "        detailsA.innerHTML = a;",
  "        detailsTs.innerHTML = ts;",
  "        detailsDur.innerHTML = dur;",
  "        detailsPc.innerHTML = pc;",
  "        if (top + detailsPopup.offsetHeight > document.body.clientHeight)",
  "            top = evt.clientY - detailsPopup.offsetHeight - 20;",
  "        detailsPopup.style.top = top;",
  "        detailsPopup.style.visibility = \"visible\";",
  "    }",
  "    function c() { detailsPopup.style.display = \"none\"; }",
  "</script>",
  "<script type=\"text/javascript\">",
  "    // Module, Function, etc",
  "    function Point(x,y) {",
  "        this.x = x;",
  "        this.y = y;",
  "    }",
  "    Point.prototype.show = function() {",
  "        return this.x + \",\" + this.y;",
  "    }",
  "     // for drawing lines from rect to rect",
  "    Point.prototype.shifted = function() {",
  "        this.x -= 2;",
  "        this.y += rectHeight/2;",
  "    }",
  "    ",
  "    function MFA(node,pid,m,f,a,ts,tf,dur,pn,color) {",
  "        this.node = node;",
  "        this.pid = pid;",
  "        this.m = m;",
  "        this.f = f;",
  "        this.a = a;",
  "        this.ts = ts;",
  "        this.tf = tf;",
  "        this.dur = dur;",
  "        this.pn = pn;",
  "        this.color = color;",
  "    }",
  "",
  "    // Node in terms of graph repr",
  "    function TreeNode(dur, mfas, parent) {",
  "      this.dur      = dur;",
  "      this.mfas     = mfas;",
  "      this.parent   = parent;",
  "      this.children = [];",
  "    };",
  "    TreeNode.prototype.find = function(pid) {",
  "        if (this.mfas[0].pid == pid) {",
  "            return this;",
  "        }",
  "        for (var i=0, l=this.children.length; i<l; i++) {",
  "            var res = this.children[i].find(pid);",
  "            if (res) {",
  "                return res;",
  "            }",
  "        }",
  "        return null;",
  "    }",
  "    TreeNode.prototype.appendChild = function(dur, mfas) {",
  "        var child = new TreeNode(dur, mfas, this);",
  "        this.children.push(child);",
  "        return this.children[this.children.length-1];",
  "    }",
  "",
  "    minWidthChanged = function() {",
  "        minWidth = parseInt(document.getElementsByName(\"minWidth\")[0].value) || minWidth;",
  "        redrawSVG(curRoot);",
  "    }",
  "",
  "    rectHeightChanged = function() {",
  "        rectHeight = parseInt(document.getElementsByName(\"rectHeight\")[0].value) || rectHeight;",
  "        redrawSVG(curRoot);",
  "    }",
  "",
  "    function redrawSVG(pid) {",
  "        curRoot = pid;",
  "        var node = treeRoot.find(pid) || treeRoot;",
  "        drawSVG(node.mfas[0].ts, node);",
  "    }",
  "",
  "    drawScaleText = function(shiftTs, ratio) {",
  "        for (var i = 0; i < 11; i++) {",
  "            var text_el = document.getElementById(\"tscale\" + i);",
  "            var line_el = document.getElementById(\"lscale\" + i);",
  "            var t = (line_el.x1.baseVal.value/ratio + shiftTs) / 1000;",
  "            text_el.textContent = t.toFixed(1) + \"ms\"",
  "        }",
  "    }",
  "",
  "    var xlinkNS=\"http://www.w3.org/1999/xlink\", svgNS=\"http://www.w3.org/2000/svg\";",
  "    drawRect = function(x,y,w,h,c,pid,fnover,svg) {",
  "        var rect = document.createElementNS(svgNS, \"rect\");",
  "        rect.setAttributeNS(null,\"x\",x);",
  "        rect.setAttributeNS(null,\"y\",y);",
  "        rect.setAttributeNS(null,\"rx\",2);",
  "        rect.setAttributeNS(null,\"ry\",2);",
  "        rect.setAttributeNS(null,\"width\",w);",
  "        rect.setAttributeNS(null,\"height\",h);",
  "        rect.setAttributeNS(null,\"fill\",c);",
  "        rect.setAttributeNS(null,\"onmouseover\",fnover);",
  "        rect.setAttributeNS(null,\"onmouseout\",\"c()\");",
  "        rect.setAttributeNS(null,\"onclick\",\"redrawSVG('\"+ pid +\"')\");",
  "        svg.appendChild(rect);",
  "    }",
  "",
  "    drawFnsSeq = function(shiftTs, ratio, mfas, svg, y) {",
  "        var g = document.createElementNS(svgNS, \"g\");",
  "        svg.appendChild(g);",
  "",
  "        g.setAttributeNS(null, \"transform\", ",
  "                \"translate(\" + (mfas[0].ts - shiftTs)*ratio + \",0)\");",
  "        // we moved coordinates, so the x = 0 is the mfas[0].ts",
  "        var xEPrev = -1",
  "        for (var i=0; i < mfas.length || 0; i++) {",
  "            var xEReal = (mfas[i].tf - mfas[0].ts) * ratio;",
  "            var wReal  = (mfas[i].tf - mfas[i].ts) * ratio;",
  "            var xS     = xEPrev + 1;",
  "            var w      = xEReal - xS;",
  "            w          = (w < minWidth) ? minWidth : w;",
  "            var xEPrev = xS + w;",
  "",
  "            var fnover = \"s(evt, \"",
  "                + \"'\" + mfas[i].node + \"', \"",
  "                + \"'\" + mfas[i].pid  + \"', \"",
  "                + \"'\" + mfas[i].m    + \"', \"",
  "                + \"'\" + mfas[i].f    + \"', \"",
  "                + \"'\" + mfas[i].a    + \"', \"",
  "                + \"'\" + (mfas[i].ts/1000).toFixed(1)  + \"ms -&gt; \"",
  "                      + (mfas[i].tf/1000).toFixed(1)  + \"ms', \"",
  "                + \"'\" + (mfas[i].dur/1000).toFixed(1) + \"ms', \"",
  "                + \"'\" + mfas[i].pn + \"')\"",
  "            drawRect(xS,y,w,rectHeight,mfas[i].color,mfas[i].pid,fnover,g)",
  "        }",
  "    }",
  "",
  "    drawLine = function(p1, p2, color, svg) {",
  "        var shift = function(p) { ",
  "            return new Point(p.x -2, p.y + rectHeight/2);",
  "        };",
  "        var pMiddle = new Point(Math.min(p1.x, p2.x), Math.max(p1.y, p2.y))",
  "        var line = document.createElementNS(svgNS, \"polyline\");",
  "        line.setAttributeNS(null,\"points\",",
  "            shift(p1).show() + \" \"",
  "            + shift(pMiddle).show() + \" \"",
  "            + shift(p2).show());",
  "        line.setAttributeNS(null,\"style\", \"shape-rendering: crispEdges; stroke-width:1; stroke:\" + color);",
  "        line.setAttributeNS(null,\"fill\", \"none\");",
  "        svg.appendChild(line);",
  "    }",
  "    ",
  "    drawNode = function(shiftTs, ratio, node, svg, y) {",
  "        drawFnsSeq(shiftTs, ratio, node.mfas, svg, y);",
  "        var pParent = new Point((node.mfas[0].ts -shiftTs) * ratio, y);",
  "        y += rectHeight + 1;",
  "        for (var i = 0; i < node.children.length; i++)",
  "        {",
  "            var pChild = new Point((node.children[i].mfas[0].ts -shiftTs) * ratio, y);",
  "            drawLine(pParent, pChild, \"blue\", svg);",
  "            y = drawNode(shiftTs, ratio, node.children[i], svg, y);",
  "        }",
  "        return y;",
  "    }",
  "",
  "    // svg repr from the node",
  "    drawSVG = function(shiftTs, node) {",
  "        var ratio = (svg_width - 20) / node.dur;",
  "        console.log(\"ratio=\" + svg_width + \"/\" + node.dur + \"=\" + ratio);",
  "        drawScaleText(shiftTs, ratio);",
  "        graph.removeChild(graph.childNodes[0]);",
  "        var g = document.createElementNS(svgNS, \"g\");",
  "        graph.appendChild(g);",
  "        var y = drawNode(shiftTs, ratio, node, g, 0);",
  "        document.getElementById(\"svg_outer\").setAttributeNS(null,\"height\", y+captionHeight+scaleHeight+10);",
  "    }",
  "",
  "</script>",
  ""]

svgFooter = [
  "<style type=\"text/css\">",
  "  body { padding: 0px; margin: 0px; }",
  "  input { width: 40; }",
  "  rect[rx] { rx:\"2\"; ry:\"2\"; cursor: pointer; }",
  "  rect[rx]:hover { stroke:black; stroke-width:1; }",
  "  /*text:hover { stroke:black; stroke-width:1; stroke-opacity:0.35; }*/",
  "  #m,#a,#f,#pid,#node,#ts,#dur,#pc { display: inline; }",
  "  #detailsPopup { padding: 5; opacity: 0.9; border-radius:20px; background-color:#90BEE3; font-size:11; position: fixed; /*border: 1px solid red;*/ display: none; }",
  "  ul { padding-left: 20px; }",
  "</style>",
  "",
  "<div id=\"detailsPopup\">",
  "    <ul>",
  "        <li> Node:         <div id=\"node\"></div> </li>",
  "        <li> Pid:          <div id=\"pid\"> </div> </li>",
  "        <li> Module:       <div id=\"m\">   </div> </li>",
  "        <li> Function:     <div id=\"f\">   </div> </li>",
  "        <li> Args:         <div id=\"a\">   </div> </li>",
  "        <li> Running Time: <div id=\"ts\">  </div> </li>",
  "        <li> Duration:     <div id=\"dur\"> </div> </li>",
  "        <li> Percentage:   <div id=\"pc\">  </div> </li>",
  "    </ul>",
  "</div>",
  "",
  "<div style=\"display:block;\">",
  "min width:<input type=\"text\" name=\"minWidth\" onKeyUp=\"minWidthChanged()\" />",
  "rect height:<input type=\"text\" name=\"rectHeight\" onKeyUp=\"rectHeightChanged()\" />",
  "</div>",
  "<svg id=\"svg_outer\" xmlns=\"http://www.w3.org/2000/svg\" ",
  "    version=\"1.1\" width=\"1000px\" height=\"700px\" ",
  "    xmlns=\"http://www.w3.org/2000/svg\" >",
  "<defs >",
  "  <linearGradient id=\"background\" y1=\"0px\" y2=\"1px\" x1=\"0px\" x2=\"0px\" >",
  "    <stop stop-color=\"#eeeeee\" offset=\"5%\" />",
  "    <stop stop-color=\"#eeeeb0\" offset=\"95%\" />",
  "  </linearGradient>",
  "</defs>",
  "<rect x=\"0px\" y=\"0px\" width=\"100%\" height=\"100%\" fill=\"url(#background)\"  />",
  "<text text-anchor=\"middle\" x=\"600px\" y=\"25px\" font-size=\"17\" font-family=\"Verdana\" fill=\"rgb(0,0,0)\"  >GTL Graph</text>",
  "",
  "<g transform=\"translate(10,40)\">",
  "    <g style=\"stroke:blue\" >",
  "    <line x1=\"0px\"  y1=\"0px\" x2=\"98%\"  y2=\"0px\" />",
  "    <line id=\"lscale0\"  x1=\"0%\"   y1=\"0px\" x2=\"0%\"  y2=\"15px\" />",
  "    <line id=\"lscale1\"  x1=\"9%\"  y1=\"0px\" x2=\"9%\"  y2=\"15px\" />",
  "    <line id=\"lscale2\"  x1=\"18%\" y1=\"0px\" x2=\"18%\" y2=\"15px\" />",
  "    <line id=\"lscale3\"  x1=\"27%\" y1=\"0px\" x2=\"27%\" y2=\"15px\" />",
  "    <line id=\"lscale4\"  x1=\"36%\" y1=\"0px\" x2=\"36%\" y2=\"15px\" />",
  "    <line id=\"lscale5\"  x1=\"45%\" y1=\"0px\" x2=\"45%\" y2=\"15px\" />",
  "    <line id=\"lscale6\"  x1=\"54%\" y1=\"0px\" x2=\"54%\" y2=\"15px\" />",
  "    <line id=\"lscale7\"  x1=\"63%\" y1=\"0px\" x2=\"63%\" y2=\"15px\" />",
  "    <line id=\"lscale8\"  x1=\"72%\" y1=\"0px\" x2=\"72%\" y2=\"15px\" />",
  "    <line id=\"lscale9\"  x1=\"81%\" y1=\"0px\" x2=\"81%\" y2=\"15px\" />",
  "    <line id=\"lscale10\" x1=\"90%\" y1=\"0px\" x2=\"90%\" y2=\"15px\" />",
  "    </g>",
  "",
  "    <g style=\"font-size:12; font-family:Verdana\">",
  "    <text id=\"tscale0\"  x=\"1%\"  y=\"13px\" ></text>",
  "    <text id=\"tscale1\"  x=\"10%\" y=\"13px\" ></text>",
  "    <text id=\"tscale2\"  x=\"19%\" y=\"13px\" ></text>",
  "    <text id=\"tscale3\"  x=\"28%\" y=\"13px\" ></text>",
  "    <text id=\"tscale4\"  x=\"37%\" y=\"13px\" ></text>",
  "    <text id=\"tscale5\"  x=\"46%\" y=\"13px\" ></text>",
  "    <text id=\"tscale6\"  x=\"55%\" y=\"13px\" ></text>",
  "    <text id=\"tscale7\"  x=\"64%\" y=\"13px\" ></text>",
  "    <text id=\"tscale8\"  x=\"73%\" y=\"13px\" ></text>",
  "    <text id=\"tscale9\"  x=\"82%\" y=\"13px\" ></text>",
  "    <text id=\"tscale10\" x=\"91%\" y=\"13px\" ></text>",
  "    </g>",
  "",
  "    <g transform=\"translate(0,25)\" id=\"graph\">",
  "    </g>",
  "",
  "</g>",
  "</svg>",
  "</body>",
  "</html>",
  ""]

-- TODO:
--   check that js and hs doesn't do the same thing
--   colorMFA : difference between letters
--   error in zooming
--   form to change minWidth + rectHeight
--   showCurPath
