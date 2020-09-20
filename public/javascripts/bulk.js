function toggleHide(id) {
  var x = document.getElementById(id);
  if (x.style.display === "none") {
    x.style.display = "block";
  } else {
    x.style.display = "none";
  }
} 

function showHide(elem) {
    if(elem.selectedIndex != 0) {
         //hide the divs
         for(var i=0; i < divsO.length; i++) {
             divsO[i].style.display = 'none';
        }
        //unhide the selected div
        document.getElementById('div'+elem.value).style.display = 'block';
    }
}
 
window.onload=function() {
    //get the divs to show/hide
    divsO = document.getElementById("showhideform").getElementsByTagName('div');
}

function GetSelectedValues(sel,area){
   var items;
   var list = document.getElementById(sel);
   var selected = new Array();
 
   for (i = 0; i < list.options.length; i++) {
      if (list.options[ i ].selected) {
         selected.push(list.options[ i ].value);
      }
   }
 
   items = selected.join('\n');
 
   document.getElementById(area).value = items;
}
