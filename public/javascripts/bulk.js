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

function openTab(evt, tabName, contentclass) {
  // Declare all variables
  var i, tabcontent, tablinks;

  // Get all elements with class="tabcontent" and hide them
  tabcontent = document.getElementsByClassName(contentclass);
  for (i = 0; i < tabcontent.length; i++) {
    tabcontent[i].style.display = "none";
  }

  // Get all elements with class="tablinks" and remove the class "active"
  tablinks = document.getElementsByClassName("tablinks");
  for (i = 0; i < tablinks.length; i++) {
    tablinks[i].className = tablinks[i].className.replace(" active", "");
  }

  // Show the current tab, and add an "active" class to the button that opened the tab
  document.getElementById(tabName).style.display = "block";
  evt.currentTarget.className += " active";
}
